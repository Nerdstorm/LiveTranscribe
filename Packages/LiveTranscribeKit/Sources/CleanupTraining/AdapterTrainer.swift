import Cleanup
import Foundation
@preconcurrency import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers

/// LoRA training settings. The defaults are what the bundled adapter was trained with.
public struct TrainingOptions: Sendable, Codable, Equatable {
    public var iterations = 600
    public var batchSize = 8
    public var learningRate: Float = 2e-5
    /// LoRA rank and scale.
    public var rank = 8
    public var scale: Float = 20
    /// Transformer layers adapted, counted from the last.
    public var layers = 16
    public var validateEvery = 50
    public var reportEvery = 10
    public var seed: UInt64 = 1

    public init() {}
}

/// What training produced, written next to the dataset for the record.
public struct TrainingReport: Sendable, Codable {
    public let baseModel: String
    public let baseRevision: String
    public let options: TrainingOptions
    public let trainExamples: Int
    public let validExamples: Int
    public let bestIteration: Int
    public let bestValidationLoss: Float
    public let validationLosses: [Int: Float]
    public let seconds: Double
}

/// Trains a LoRA adapter on the cleanup model with next-token loss on the target tokens only,
/// and saves the best one (by validation loss) in mlx's adapter format.
public enum AdapterTrainer {
    public static func train(
        container: ModelContainer,
        baseModel: String,
        baseRevision: String,
        train: [TrainingExample],
        valid: [TrainingExample],
        template: PromptTemplate,
        contextLimit: Int,
        options: TrainingOptions,
        output: URL,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> TrainingReport {
        try await container.perform(values: TrainingJob(train: train, valid: valid)) { context, job in
            let started = Date()
            let tokenize = { (example: TrainingExample) in
                try TrainingText.tokenize(example, template: template, contextLimit: contextLimit, tokenizer: context.tokenizer)
            }
            let trainSet = try job.train.map(tokenize)
            let validSet = try job.valid.map(tokenize)
            log("Tokenized \(trainSet.count) training and \(validSet.count) validation examples")

            let configuration = LoRAConfiguration(
                numLayers: options.layers,
                fineTuneType: .lora,
                loraParameters: .init(rank: options.rank, scale: options.scale)
            )
            // LoRA's A matrices start random; seeding makes a run reproducible.
            MLXRandom.seed(options.seed)
            _ = try LoRAContainer.from(model: context.model, configuration: configuration)
            let model: Module = context.model

            let optimizer = Adam(learningRate: options.learningRate)
            let lossAndGradient = valueAndGrad(model: model) { model, arrays in
                maskedLoss(model: model, inputs: arrays[0], targets: arrays[1], mask: arrays[2])
            }

            var rng = SeededGenerator(seed: options.seed)
            var order: [Int] = []
            var losses: [Float] = []
            var validationLosses: [Int: Float] = [:]
            var best = (iteration: 0, loss: Float.infinity)

            for iteration in 1...options.iterations {
                if order.count < options.batchSize {
                    order += Array(trainSet.indices).shuffled(using: &rng)
                }
                let batch = order.prefix(options.batchSize).map { trainSet[$0] }
                order.removeFirst(min(options.batchSize, order.count))

                let (inputs, targets, mask) = arrays(for: batch)
                let (values, gradients) = lossAndGradient(model, [inputs, targets, mask])
                optimizer.update(model: model, gradients: gradients)
                eval(model, optimizer, values[0])
                losses.append(values[0].item(Float.self))

                if iteration % options.reportEvery == 0 {
                    let mean = losses.suffix(options.reportEvery).reduce(0, +) / Float(options.reportEvery)
                    log(String(format: "Iteration %d: training loss %.4f", iteration, mean))
                }
                if iteration % options.validateEvery == 0 || iteration == options.iterations {
                    let loss = validationLoss(model: model, examples: validSet, batchSize: options.batchSize)
                    validationLosses[iteration] = loss
                    log(String(format: "Iteration %d: validation loss %.4f", iteration, loss))
                    if loss < best.loss {
                        best = (iteration, loss)
                        try save(model: model, configuration: configuration, baseModel: baseModel, baseRevision: baseRevision, to: output)
                        log("Saved the adapter (best so far) to \(output.path)")
                    }
                }
            }

            return TrainingReport(
                baseModel: baseModel,
                baseRevision: baseRevision,
                options: options,
                trainExamples: trainSet.count,
                validExamples: validSet.count,
                bestIteration: best.iteration,
                bestValidationLoss: best.loss,
                validationLosses: validationLosses,
                seconds: Date().timeIntervalSince(started)
            )
        }
    }

    /// Mean cross-entropy over target tokens. `mask` marks the positions whose next token is
    /// part of the target.
    static func maskedLoss(model: Module, inputs: MLXArray, targets: MLXArray, mask: MLXArray) -> [MLXArray] {
        let model = model as! any LLMModel
        let logits = model(inputs, cache: nil).asType(.float32)
        let tokenCount = mask.sum()
        let loss = (crossEntropy(logits: logits, targets: targets) * mask).sum() / tokenCount
        return [loss, tokenCount]
    }

    /// The batch as model inputs, next-token targets and the target-token mask.
    static func arrays(for batch: [TokenizedExample]) -> (MLXArray, MLXArray, MLXArray) {
        let padded = PaddedBatch(batch)
        let shape = [padded.rows, padded.width]
        return (MLXArray(padded.inputs, shape), MLXArray(padded.targets, shape), MLXArray(padded.mask, shape))
    }

    static func validationLoss(model: Module, examples: [TokenizedExample], batchSize: Int) -> Float {
        var weightedLoss: Float = 0
        var tokens: Float = 0
        for start in stride(from: 0, to: examples.count, by: batchSize) {
            let batch = Array(examples[start..<min(start + batchSize, examples.count)])
            let (inputs, targets, mask) = arrays(for: batch)
            let values = maskedLoss(model: model, inputs: inputs, targets: targets, mask: mask)
            eval(values)
            let count = values[1].item(Float.self)
            weightedLoss += values[0].item(Float.self) * count
            tokens += count
        }
        return tokens > 0 ? weightedLoss / tokens : .nan
    }

    /// Writes the trainable (LoRA) weights as float16 and the adapter configuration, including
    /// the base model and commit that ``CleanupAdapter`` checks before fusing.
    static func save(model: Module, configuration: LoRAConfiguration, baseModel: String, baseRevision: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var weights: [String: MLXArray] = [:]
        for (key, value) in model.trainableParameters().flattened() {
            weights[key] = value.asType(.float16)
        }
        try MLX.save(arrays: weights, url: directory.appending(component: CleanupAdapter.weightsFile))

        let file = AdapterConfigurationFile(
            fineTuneType: configuration.fineTuneType.rawValue,
            numLayers: configuration.numLayers,
            loraParameters: .init(rank: configuration.loraParameters.rank, scale: configuration.loraParameters.scale),
            baseModel: baseModel,
            baseRevision: baseRevision
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: directory.appending(component: CleanupAdapter.configurationFile))
    }
}

/// The examples, sent into the model container's isolation.
private struct TrainingJob: Sendable {
    let train: [TrainingExample]
    let valid: [TrainingExample]
}

/// mlx's `adapter_config.json`, extended with the base model and commit.
struct AdapterConfigurationFile: Codable {
    struct Parameters: Codable {
        let rank: Int
        let scale: Float
    }

    let fineTuneType: String
    let numLayers: Int
    let loraParameters: Parameters
    let baseModel: String
    let baseRevision: String

    enum CodingKeys: String, CodingKey {
        case fineTuneType = "fine_tune_type"
        case numLayers = "num_layers"
        case loraParameters = "lora_parameters"
        case baseModel = "base_model"
        case baseRevision = "base_revision"
    }
}
