#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import TelegramSchema

/// Bounded inspection of serialized RPC requests for payload-free diagnostics.
/// The supported layouts follow the generated schema; unknown requests remain usable.
public enum RPCRequestSummary {
  private struct Method: Sendable {
      let name: String
      var peerOffset: Int? = nil
      var vector = false
      var bareChat = false
      var leadingStringFlag: UInt32? = nil
  }
  /// Reads only a known method's constructor and leading peer identifier. Never decodes
  /// access hashes or message bodies. Malformed/truncated peers produce nil; unknown
  /// methods retain their hexadecimal constructor ID. No I/O or cancellation is involved.
  public static func describe(_ data: Data) -> (name: String, peer: String?) {
      func uint32(_ offset: Int) -> UInt32? {
          guard offset >= 0, data.count >= offset + 4 else { return nil }
          return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << ($1 * 8) }
      }
      func int64(_ offset: Int) -> Int64? {
          guard let low = uint32(offset), let high = uint32(offset + 4) else { return nil }
          return Int64(bitPattern: UInt64(low) | UInt64(high) << 32)
      }
      guard let id = uint32(0) else { return ("invalid TL request", nil) }
      guard let method = methods[id] else { return ("TL constructor 0x" + String(id, radix: 16), nil) }
      guard var offset = method.peerOffset else { return (method.name, nil) }
      var suffix = ""
      if let flag = method.leadingStringFlag, let flags = uint32(4), flags & flag != 0 {
          guard offset < data.count else { return (method.name, nil) }
          let first = Int(data[data.startIndex + offset])
          let header: Int
          let length: Int
          if first < 254 { header = 1; length = first }
          else {
              guard first == 254, let bytes = uint32(offset) else { return (method.name, nil) }
              header = 4; length = Int(bytes >> 8)
          }
          offset += (header + length + 3) & ~3
      }
      if method.vector {
          guard uint32(offset) == 0x1cb5c415, let count = uint32(offset + 4), count > 0 else { return (method.name, nil) }
          offset += 8
          if count > 1 { suffix = " (+\(count - 1) peers)" }
      }
      if method.bareChat { return (method.name, int64(offset).map { "chat:\($0)" + suffix }) }
      guard let constructor = uint32(offset) else { return (method.name, nil) }
      let kind: String
      switch constructor {
      case 0xdde8a54c, 0xf21158c6: kind = "user" // inputPeerUser, inputUser
      case 0x27bcbbfc, 0xf35aec28: kind = "channel" // inputPeerChannel, inputChannel
      case 0x35a95cb9: kind = "chat" // inputPeerChat
      case 0x7da07ec9, 0xf7c1b13f: return (method.name, "self" + suffix)
      default: return (method.name, nil) // From-message and future constructors: inherited context instead.
      }
      return (method.name, int64(offset + 4).map { "\(kind):\($0)" + suffix })
  }

  // Constructor IDs and leading-peer offsets from the pinned Telegram schema.
  // Only the leading peer identifier is read, never access hashes or text.
  // Unknown/new methods still report their constructor ID and task context.
  private static let methods: [UInt32: Method] = [
      TL.Auth.LogOut.tlConstructorID: Method(name: "auth.logOut"),
      TL.Payments.GetSavedStarGift.tlConstructorID: Method(name: "payments.getSavedStarGift"),
      TL.Payments.GetSavedStarGifts.tlConstructorID: Method(name: "payments.getSavedStarGifts", peerOffset: 8),
      TL.Bots.ResetBotCommands.tlConstructorID: Method(name: "bots.resetBotCommands"),
      TL.Bots.SetBotCommands.tlConstructorID: Method(name: "bots.setBotCommands"),
      TL.Channels.DeleteMessages.tlConstructorID: Method(name: "channels.deleteMessages", peerOffset: 4),
      TL.Channels.EditBanned.tlConstructorID: Method(name: "channels.editBanned", peerOffset: 4),
      TL.Channels.GetChannels.tlConstructorID: Method(name: "channels.getChannels", peerOffset: 4, vector: true),
      TL.Channels.GetFullChannel.tlConstructorID: Method(name: "channels.getFullChannel", peerOffset: 4),
      TL.Channels.GetMessages.tlConstructorID: Method(name: "channels.getMessages", peerOffset: 4),
      TL.Channels.GetParticipant.tlConstructorID: Method(name: "channels.getParticipant", peerOffset: 4),
      TL.Channels.GetParticipants.tlConstructorID: Method(name: "channels.getParticipants", peerOffset: 4),
      TL.Ephemeral.DeleteMessage.tlConstructorID: Method(name: "ephemeral.deleteMessage", peerOffset: 8),
      TL.Ephemeral.EditMessage.tlConstructorID: Method(name: "ephemeral.editMessage", peerOffset: 8),
      TL.Ephemeral.SendMessage.tlConstructorID: Method(name: "ephemeral.sendMessage", peerOffset: 8),
      TL.Help.GetConfig.tlConstructorID: Method(name: "help.getConfig"),
      TL.Messages.CreateForumTopic.tlConstructorID: Method(name: "messages.createForumTopic", peerOffset: 8),
      TL.Messages.DeleteChatUser.tlConstructorID: Method(name: "messages.deleteChatUser", peerOffset: 8, bareChat: true),
      TL.Messages.DeleteMessages.tlConstructorID: Method(name: "messages.deleteMessages"),
      TL.Messages.DeleteTopicHistory.tlConstructorID: Method(name: "messages.deleteTopicHistory", peerOffset: 4),
      TL.Messages.EditForumTopic.tlConstructorID: Method(name: "messages.editForumTopic", peerOffset: 8),
      TL.Messages.EditMessage.tlConstructorID: Method(name: "messages.editMessage", peerOffset: 8),
      TL.Messages.ForwardMessages.tlConstructorID: Method(name: "messages.forwardMessages", peerOffset: 8),
      TL.Messages.GetChats.tlConstructorID: Method(name: "messages.getChats", peerOffset: 4, vector: true, bareChat: true),
      TL.Messages.GetCustomEmojiDocuments.tlConstructorID: Method(name: "messages.getCustomEmojiDocuments"),
      TL.Messages.GetFeaturedEmojiStickers.tlConstructorID: Method(name: "messages.getFeaturedEmojiStickers"),
      TL.Messages.GetFeaturedStickers.tlConstructorID: Method(name: "messages.getFeaturedStickers"),
      TL.Messages.GetOldFeaturedStickers.tlConstructorID: Method(name: "messages.getOldFeaturedStickers"),
      TL.Messages.GetForumTopicsByID.tlConstructorID: Method(name: "messages.getForumTopicsByID", peerOffset: 4),
      TL.Messages.GetFullChat.tlConstructorID: Method(name: "messages.getFullChat", peerOffset: 4, bareChat: true),
      TL.Messages.GetMessages.tlConstructorID: Method(name: "messages.getMessages"),
      TL.Messages.GetStickerSet.tlConstructorID: Method(name: "messages.getStickerSet"),
      TL.Messages.HideChatJoinRequest.tlConstructorID: Method(name: "messages.hideChatJoinRequest", peerOffset: 8),
      TL.Messages.SendMedia.tlConstructorID: Method(name: "messages.sendMedia", peerOffset: 8),
      TL.Messages.SendMessage.tlConstructorID: Method(name: "messages.sendMessage", peerOffset: 8),
      TL.Messages.SetBotCallbackAnswer.tlConstructorID: Method(name: "messages.setBotCallbackAnswer"),
      TL.Messages.SetBotPrecheckoutResults.tlConstructorID: Method(name: "messages.setBotPrecheckoutResults"),
      TL.Messages.SetTyping.tlConstructorID: Method(name: "messages.setTyping", peerOffset: 8),
      TL.Messages.UpdatePinnedMessage.tlConstructorID: Method(name: "messages.updatePinnedMessage", peerOffset: 8),
      TL.Messages.UploadMedia.tlConstructorID: Method(name: "messages.uploadMedia", peerOffset: 8, leadingStringFlag: 1),
      TL.Payments.BotCancelStarsSubscription.tlConstructorID: Method(name: "payments.botCancelStarsSubscription", peerOffset: 8),
      TL.Payments.ExportInvoice.tlConstructorID: Method(name: "payments.exportInvoice"),
      TL.Payments.RefundStarsCharge.tlConstructorID: Method(name: "payments.refundStarsCharge", peerOffset: 4),
      TL.Updates.GetChannelDifference.tlConstructorID: Method(name: "updates.getChannelDifference", peerOffset: 8),
      TL.Updates.GetDifference.tlConstructorID: Method(name: "updates.getDifference"),
      TL.Updates.GetState.tlConstructorID: Method(name: "updates.getState"),
      TL.Upload.GetFile.tlConstructorID: Method(name: "upload.getFile"),
      TL.Upload.SaveBigFilePart.tlConstructorID: Method(name: "upload.saveBigFilePart"),
      TL.Upload.SaveFilePart.tlConstructorID: Method(name: "upload.saveFilePart"),
      TL.Users.GetFullUser.tlConstructorID: Method(name: "users.getFullUser", peerOffset: 4),
      TL.Users.GetUsers.tlConstructorID: Method(name: "users.getUsers", peerOffset: 4, vector: true),
  ]
}
