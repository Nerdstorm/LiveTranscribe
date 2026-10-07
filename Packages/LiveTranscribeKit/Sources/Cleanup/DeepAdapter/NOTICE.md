# Deep cleanup adapter — F4

Copyright (c) 2026 Nerdstorm. Nerdstorm's adapter contribution is released under the
repository's MIT License. This does not relicense the base model or the source datasets.

This is F4 checkpoint **1950**, the Deep adapter in Live Transcribe 1.3.0. It is a LoRA
adapter for Qwen3-1.7B by the Qwen team, Alibaba Cloud, converted by mlx-community:

- Base: https://huggingface.co/mlx-community/Qwen3-1.7B-4bit
- Base revision: `3b1b1768f8f8cf8351c712464f906e86c2b8269e`
- Original model: https://huggingface.co/Qwen/Qwen3-1.7B — Apache License 2.0
- Weight SHA-256: `d6814f8e23b247080a4e892cc569405621c5504a3205095a9a028d6f045d5daa`
- Config SHA-256: `4da7a22747aee524dd279579f7deabd20bf6da0ba6381acf0a87bce23309679e`

`adapters.safetensors` contains the weights. `adapter_config.json` pins the base revision
and the LoRA shape: rank 8, scale 20, last 16 layers. Medium and High use the separate
adapter in `../Adapter`; its weights are unchanged.

Training combined synthetic dictations, their measured macOS text-to-speech recognizer
transcripts, synthetic app requests and public written correction pairs. No private
history, private audio or sealed acceptance examples were used. Public pairs were
selected, converted into app raw/target pairs, assigned source families and separate
splits, and supplemented with labelled synthetic variants. Dataset rows are not bundled.

## Public training sources

**Disfl-QA**, by Aditya Gupta, Jiacheng Xu, Shyam Upadhyay, Diyi Yang and Manaal Faruqui,
*Disfl-QA: A Benchmark Dataset for Understanding Disfluencies in Question Answering*
(Findings of ACL 2021). Google Research publishes it under **CC BY 4.0**:

- https://github.com/google-research-datasets/Disfl-QA
- Pinned revision: `1f0c16171c77b3d3408be92c485f11b8998a9189`
- Licence: https://creativecommons.org/licenses/by/4.0/

Disfl-QA derives its questions from **SQuAD 2.0**, by Pranav Rajpurkar, Robin Jia and
Percy Liang, *Know What You Don't Know: Unanswerable Questions for SQuAD* (ACL 2018).
That upstream dataset retains **CC BY-SA 4.0**:

- https://rajpurkar.github.io/SQuAD-explorer/
- https://github.com/rajpurkar/SQuAD-explorer
- Pinned revision: `e0c66cfec263165fb3c15cb76a22175e371b71d7`
- Licence: https://creativecommons.org/licenses/by-sa/4.0/

**ErAConD**, by YUAN Xun and contributors, provides written grammatical correction pairs
under **MIT**:

- https://github.com/yuanxun-yx/eracond
- Pinned revision: `8401d3601f58170b55f0b1ca3773329c56b116f9`
- Original copyright and permission text are retained below.

These credits do not imply endorsement. Source datasets retain their licences, including
attribution and ShareAlike for applicable redistributions of SQuAD-derived text. F4 does
not include DisfluencySpeech, Switchboard, LibriSpeech or LibriTTS material.

## Results and limitations

F4 was selected using validation loss, not test scores. Completed development checks
found gains in public question corrections and some app requests, but regressions in
grammar, vocabulary and lists, including unsupported word/clause joins and lost bullets.
It failed the original promotion gates. The owner later chose to ship this exact
checkpoint. No independent human acceptance or cross-platform quality gain is claimed.
See https://github.com/Nerdstorm/LiveTranscribe/blob/main/docs/deep-f4-release.md for the
complete comparison and release decision.

## ErAConD licence

MIT License

Copyright (c) 2022 YUAN Xun

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
