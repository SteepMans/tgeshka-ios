import Foundation
import Postbox

// TGeshka: easter egg (пасхалка), the rules from tgeshka-easter-egg.txt in the app bundle
// (Telegram/BUILD resources). Outside the main app there is no file and nothing changes.
private let tgeshkaEasterEggRules: TGeshkaEasterEggRules = {
    guard let url = Bundle.main.url(forResource: "tgeshka-easter-egg", withExtension: "txt"), let data = try? Data(contentsOf: url), let content = String(data: data, encoding: .utf8) else {
        return TGeshkaEasterEggRules()
    }
    return TGeshkaEasterEggRules(content: content)
}()

// TGeshka: new outgoing text messages without media and formatting get the easter egg.
func tgeshkaApplyEasterEgg(_ messages: [EnqueueMessage]) -> [EnqueueMessage] {
    return messages.map { message -> EnqueueMessage in
        guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = message, mediaReference == nil, !text.isEmpty else {
            return message
        }
        for attribute in attributes {
            if let attribute = attribute as? TextEntitiesMessageAttribute, !attribute.entities.isEmpty {
                return message
            }
        }
        guard let updated = tgeshkaEasterEggRules.apply(text) else {
            return message
        }
        return .message(text: updated, attributes: attributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
    }
}
