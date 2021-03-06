//
// Created by Erik Little on 4/9/18.
//

import Foundation
import Kit

/// An accident type. These are the different effects that can happen.
public enum AccidentType : Encodable, RandomCasable {
    /// All accidents.
    public static let allCases: [AccidentType] = [.strike(.any)]

    /// A strike. This causes all workers of a certain `SkillType` to be taken out of play for 3 turns.
    case strike(SkillType)

    public static var randomCase: AccidentType {
        return .strike(.randomCase)
    }

    /// The number of turns this accident is active.
    var turnsActive: Int {
        switch self {
        case .strike:
            return 3
        }
    }

    public func encode(to encoder: Encoder) throws {
        var containter = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .strike(type):
            try containter.encode(type, forKey: .strike)
        }
    }

    private enum CodingKeys : CodingKey {
        case strike
    }
}

/// An accident playable. These cards affect the status of the game. Such as injuring workers or causing strikes.
public struct Accident : BuildersPlayable, Encodable {
    /// The type of this playable.
    public let playType = BuildersPlayType.accident

    /// The id of this accident.
    public let id = UUID()

    /// The type of this accident.
    public let type: AccidentType

    /// The number of turns this accident has been in effect.
    public var turns = 0

    init(type: AccidentType, turns: Int = 0) {
        self.type = type
        self.turns = turns
    }

    /// Returns whether or not this playable can be played by player.
    ///
    /// - parameter givenState: The state this playable is being used in.
    /// - parameter byPlayer: The player playing.
    public func canPlay(givenState context: BuildersBoardState, byPlayer player: BuilderPlayer) -> Bool {
        return true
    }

    /// Whether or not this accident affects the given `BuildersPlayable`.
    ///
    /// - parameter playable: The `BuildersPlayable` that is being tested.
    /// - returns: Whether or not this accident is affecting the playable.
    public func affectsPlayable(_ playable: BuildersPlayable) -> Bool {
        switch (type, playable) {
        case let (.strike(skillType), worker as Worker):
            return worker.skill == skillType
        case _:
            return false
        }
    }

    /// Creates a random instance of this playable.
    public static func getInstance() -> Accident {
        return Accident(type: .randomCase)
    }
}


