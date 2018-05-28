//
// Created by Erik Little on 5/27/18.
//

import Foundation

/// Represents the top level message structure that goes from the server to a player.
public struct UserInteraction<InteractionType: Encodable> : Encodable {

    // FIXME find a better name for the inner InteractionType
    /// The type of interaction this is.
    public var type: Kit.InteractionType

    /// Represents the interaction for this message. This can be anything that is `Encodable`.
    public var interaction: InteractionType

    // TODO docstring
    public init(type: Kit.InteractionType, interaction: InteractionType) {
        self.type = type
        self.interaction = interaction
    }
}

/// The set of events that can happen during a game.
public enum InteractionType : String, Encodable {
    /// Sent when the server has a message that should be shown.
    case dialog

    /// The game has ended.
    case gameOver

    /// The player did something illegal.
    case playError

    /// Sent when a player starts their turn.
    case turnStart

    /// Sent during each part of a turn.
    case turn

    /// Sent when a player's turn is over.
    case turnEnd
}