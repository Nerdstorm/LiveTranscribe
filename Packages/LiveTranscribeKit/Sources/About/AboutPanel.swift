import AppKit
import Shared

/// The standard About panel, with credits for the models and the licence notices of every package
/// the app is built with, which a downloaded build must carry.
@MainActor
public enum AboutPanel {
    public static func show() {
        let acknowledgements: Acknowledgements?
        do {
            acknowledgements = try .bundled()
        } catch {
            Log.app.error("Couldn't read the licence notices for About: \(error.localizedDescription, privacy: .public)")
            acknowledgements = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: AboutCredits.text(acknowledgements: acknowledgements, models: ModelCredit.defaults),
        ])
    }
}

/// The About panel's credits. Built in code rather than read from a Credits.html, whose text
/// stays black in Dark Mode.
enum AboutCredits {
    static func text(acknowledgements: Acknowledgements?, models: [ModelCredit]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(paragraph("Free and open source under the MIT License.", .body))

        text.append(paragraph("Models, downloaded on first launch", .heading))
        for model in models {
            text.append(paragraph("\(model.role): \(model.original). \(model.licence). From \(model.repository).", .body))
        }

        text.append(paragraph("Open-source packages", .heading))
        guard let acknowledgements else {
            text.append(paragraph(
                "The licence notices are missing from this copy of the app. Each package's licence is in its repository.",
                .body
            ))
            return text
        }
        for package in acknowledgements.packages {
            text.append(paragraph("\(package.name) \(package.version)", .packageName))
            text.append(paragraph(package.url, .caption))
            for notice in package.notices {
                if package.notices.count > 1 {
                    text.append(paragraph(notice.file, .caption))
                }
                text.append(paragraph(notice.text, .licence))
            }
        }
        return text
    }

    enum Style {
        case heading, packageName, body, caption, licence
    }

    private static func paragraph(_ string: String, _ style: Style) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        let small = NSFont.smallSystemFontSize
        let font: NSFont
        let color: NSColor
        switch style {
        case .heading:
            paragraph.paragraphSpacingBefore = 10
            font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            color = .labelColor
        case .packageName:
            paragraph.paragraphSpacingBefore = 8
            paragraph.paragraphSpacing = 1
            font = .boldSystemFont(ofSize: small)
            color = .labelColor
        case .body:
            font = .systemFont(ofSize: small)
            color = .labelColor
        case .caption:
            paragraph.paragraphSpacing = 2
            font = .systemFont(ofSize: small - 1)
            color = .secondaryLabelColor
        case .licence:
            font = .monospacedSystemFont(ofSize: small - 2, weight: .regular)
            color = .secondaryLabelColor
        }
        return NSAttributedString(
            string: string + "\n",
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }
}
