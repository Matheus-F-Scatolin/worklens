import AppKit
import SwiftUI

/// The marks of the services Settings → Connections names: Claude, Gemini and OpenAI (for Codex).
///
/// Drawn from SVG kept here as text, because the package ships no asset catalog and the marks
/// are small enough to carry inline. `NSImage` reads SVG natively and keeps it vector, so a mark
/// is sharp at any size and on any display. The paths are Simple Icons' (CC0); the marks
/// themselves belong to Anthropic, Google and OpenAI and are used only to name their products.
enum BrandMark: String, CaseIterable {
    case claude
    case gemini
    case openAI

    /// OpenAI's mark is one colour, so it is drawn as a template and takes the text colour —
    /// black on ivory, white in dark mode. The other two keep their own colours.
    var isTemplate: Bool { self == .openAI }

    /// Built once per mark: the parse is not free and a Settings pane redraws often.
    @MainActor var image: NSImage {
        if let cached = Self.cache[self] { return cached }
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = isTemplate
        Self.cache[self] = image
        return image
    }

    @MainActor private static var cache: [BrandMark: NSImage] = [:]

    private var svg: String {
        switch self {
        case .claude:
            return document(##"<path fill="#D97757" d="\##(Self.claudePath)"/>"##)
        case .gemini:
            // The 2025 mark: blue, with red, yellow and green rising out of the top, left and
            // bottom points. Four fills of one shape, each a colour fading out from its point.
            let glows = [("r", 12, 1, "#FF4641"), ("y", 1, 12, "#FFD314"), ("g", 12, 23, "#00B95C")]
            let defs = glows.map { id, x, y, color in
                ##"<radialGradient id="\##(id)" cx="\##(x)" cy="\##(y)" r="10" gradientUnits="userSpaceOnUse">"##
                    + ##"<stop offset="0" stop-color="\##(color)"/>"##
                    + ##"<stop offset="1" stop-color="\##(color)" stop-opacity="0"/></radialGradient>"##
            }.joined()
            let fills = ["#3186FF"] + glows.map { "url(#\($0.0))" }
            let paths = fills.map { ##"<path fill="\##($0)" d="\##(Self.geminiPath)"/>"## }.joined()
            return document("<defs>\(defs)</defs>\(paths)")
        case .openAI:
            return document(##"<path fill="#000" d="\##(Self.openAIPath)"/>"##)
        }
    }

    /// No `xmlns`: `NSImage` draws the same without it, and it is not an address Worklens reaches.
    private func document(_ body: String) -> String {
        #"<svg viewBox="0 0 24 24" width="24" height="24">"# + body + "</svg>"
    }

    private static let claudePath = """
        m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729
        -2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797
        -.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336
        -.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578
        -1.0078.6557
        -.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457
        -.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607
        -.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0
        l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255
        h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468
        -.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429
        -.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293
        -.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535
        -.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614
        -3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621
        l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113
        -.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34
        -.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17
        l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246
        L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614
        -.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425
        -.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667
        -.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164
        -1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z
        """.replacingOccurrences(of: "\n", with: "")

    private static let geminiPath = """
        M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12
        q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0
        q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12
        q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81
        """.replacingOccurrences(of: "\n", with: "")

    private static let openAIPath = """
        M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9
        A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0
        -3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001
        A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718
        -4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729z
        m-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582
        a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826
        a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137
        l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1
        -.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956
        a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543
        -2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872z
        m16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913
        a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142
        -.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284
        -.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638
        a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805
        L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998
        v2.9994l-2.5974 1.4997-2.6067-1.4997Z
        """.replacingOccurrences(of: "\n", with: "")
}
