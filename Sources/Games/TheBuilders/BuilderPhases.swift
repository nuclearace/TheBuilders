//
// Created by Erik Little on 4/17/18.
//

import Foundation
import Kit
import NIO

/// Represents a phase of a turn.
protocol BuilderPhase {
    /// The context that everything is working in.
    var context: BuildersBoard? { get }

    /// Executes this phase with context.
    func doPhase() -> EventLoopFuture<()>
}

/// The names of player facing phases of a turn. These do not have to match the number of internal `BuilderPhase`s.
public enum BuildersPlayerPhaseName : String, Encodable {
    /// The player is going to place some cards on the board.
    case play

    /// The player is going to throw away some cards.
    case discard

    /// The player is going to draw some new cards.
    case draw

    /// This turn has progressed into the absolute phase of the game, the end.
    case gameOver
}

private func newFuturePhase(to phase: BuilderPhase) -> EventLoopFuture<BuilderPhase> {
    guard let context = phase.context else {
        return currentEventLoop.newFailedFuture(error: BuildersError.gameDeath)
    }

    return context.runLoop.newSucceededFuture(result: phase)
}


func ~~> (lhs: BuilderPhase, rhs: BuilderPhase) -> EventLoopFuture<BuilderPhase> {
    return lhs.doPhase().then({_ in
        return newFuturePhase(to: rhs)
    })
}

func ~~> (lhs: EventLoopFuture<BuilderPhase>, rhs: BuilderPhase) -> EventLoopFuture<BuilderPhase> {
    return lhs.then({phase in
        return phase.doPhase().then({_ in
            return newFuturePhase(to: rhs)
        })
    })
}

/// The start of a turn.
struct StartPhase : BuilderPhase {
    private(set) weak var context: BuildersBoard?

    func doPhase() -> EventLoopFuture<()> {
        guard let context = context else { return deadGame }

        context.activePlayer.send(UserInteraction(type: .turnStart, interaction: BuildersInteraction()))

        return context.runLoop.newSucceededFuture(result: ())
    }
}

/// A phase that goes through all cards in play and removes any accidents that have expired.
///
/// The count phase is followed by the deal phase.
struct CountPhase : BuilderPhase {
    private(set) weak var context: BuildersBoard?

    func doPhase() -> EventLoopFuture<()> {
        guard let context = context else { return deadGame }

        let active = context.activePlayer

        // Filter out accidents that aren't valid anymore
        context.accidents[active] = context.accidents[active, default: []].filter({accident in
            return accident.turns < accident.type.turnsActive
        })

        return context.runLoop.newSucceededFuture(result: ())
    }
}

/// During the deal phase the player picks what playables they went to put into the game.
///
/// The deal phase is followed by the build phase.
struct DealPhase : BuilderPhase {
    private enum DealType : String {
        case play, discard
    }

    private typealias HandReducer = (kept: BuildersHand, play: BuildersHand)

    private(set) weak var context: BuildersBoard?

    func doPhase() -> EventLoopFuture<()> {
        guard let context = context else { return deadGame }

        let active: BuilderPlayer = context.activePlayer

        var playedSomething = false
        var discardedSomething = false

        // These are strong captures, but if something happens, like a user disconnects, the promise will communicate
        // communicate a gameDeath error
        return getCardsToPlay(fromPlayer: active).then {[weak context] cards -> EventLoopFuture<()> in
            guard let context = context else { return deadGame }

            // Get the cards to play
            guard let played = self.playCards(cards, forPlayer: active, context: context) else {
                active.send(
                        UserInteraction(type: .playError,
                                        interaction: BuildersInteraction(dialog: ["You played a card that you " +
                                                "currently are unable to play"]))
                )

                return context.runLoop.newFailedFuture(error: BuildersError.badPlay)
            }

            playedSomething = played.count > 0

            return context.runLoop.newSucceededFuture(result: ())
        }.then {_ -> EventLoopFuture<Set<Int>> in
            // Get cards to discard
            return self.getCardsToDiscard(fromPlayer: active)
        }.then {[weak context] cards -> EventLoopFuture<()> in
            guard let context = context else { return deadGame }

            // Discard those cards
            discardedSomething = cards.count > 0

            active.hand = active.hand.enumerated().filter({ !cards.contains($0.offset + 1) }).map({ $0.element })

            // TODO Should they have to play something?
            guard playedSomething || discardedSomething else {
                active.send(
                        UserInteraction(type: .playError,
                                        interaction: BuildersInteraction(dialog: ["You must do something!"]))
                )

                return context.runLoop.newFailedFuture(error: BuildersError.badPlay)
            }

            return context.runLoop.newSucceededFuture(result: ())
        }
    }

    private func getCardsToPlay(fromPlayer player: BuilderPlayer) -> EventLoopFuture<Set<Int>> {
        assert(context != nil)

        let input = player.getInput(
                UserInteraction(type: .turn,
                                interaction: BuildersInteraction(phase: .play, hand: player.hand)
                )
        )

        return input.map({[handCount = player.hand.count] response in
            guard case let .play(played) = response else {
                return []
            }

            return DealPhase.filterInvalidCards(indexes: played, handCount: handCount)
        })
    }

    private func getCardsToDiscard(fromPlayer player: BuilderPlayer) -> EventLoopFuture<Set<Int>> {
        // TODO finish the rest of this, need to change this to the new signature, change dicts to actual types etc
        let input = player.getInput(
                UserInteraction(type: .turn,
                                interaction: BuildersInteraction(phase: .discard,
                                                                 dialog: ["Would you like discard something?"],
                                                                 hand: player.hand)))

        return input.map({[handCount = player.hand.count] response in
            guard case let .discard(discarded) = response else {
                return []
            }

            return DealPhase.filterInvalidCards(indexes: discarded, handCount: handCount)
        })
    }

    private static func filterInvalidCards(indexes: [Int], handCount: Int) -> Set<Int> {
        return Set(indexes.filter({ $0 > 0 && $0 <= handCount }))
    }

    private func playCards(_ cards: Set<Int>, forPlayer player: BuilderPlayer, context: BuildersBoard) -> BuildersHand? {
        // Split into kept and played
        let enumeratedHand = player.hand.enumerated()
        let (kept, played) = enumeratedHand.reduce(into: ([], []), {(reducer: inout HandReducer, playable) in
            switch cards.contains(playable.offset + 1) {
            case true:
                reducer.play.append(playable.element)
            case false:
                reducer.kept.append(playable.element)
            }
        })

        // Check that all cards played are allowed
        for playedCard in played where !playedCard.canPlay(inContext: context, byPlayer: player) {
            return nil
        }

        player.hand = kept
        context.accidents[context.players[1]] = played.accidents
        context.cardsInPlay[player, default: []].append(contentsOf: played.filter({ $0.playType != .accident }))

        return played
    }
}

/// During the build the phase, we calculate whether or not player built a new floor or not.
///
/// The build phase is followed by the draw phase.
struct BuildPhase : BuilderPhase {
    private(set) weak var context: BuildersBoard?

    func doPhase() -> EventLoopFuture<()> {
        guard let context = context else { return deadGame }

        let active: BuilderPlayer = context.activePlayer
        var hotel = context.hotels[active, default: Hotel()]

        guard var hand = context.cardsInPlay[active] else {
            return context.runLoop.newSucceededFuture(result: ())
        }

        defer {
            context.cardsInPlay[active] = hand
            context.hotels[active] = hotel
        }

        hotel.calculateNewFloors(fromPlayedCards: &hand)

        return context.runLoop.newSucceededFuture(result: ())
    }
}

/// During the draw phase, the player's hand is restocked with playables.
///
/// The draw phase concludes a turn.
struct DrawPhase : BuilderPhase {
    private(set) weak var context: BuildersBoard?

    func doPhase() -> EventLoopFuture<()> {
        guard let context = context else { return deadGame }

        let active: BuilderPlayer = context.activePlayer

        print("\(context.activePlayer.id) should draw some cards")

        return getCards(needed: BuildersRules.cardsNeededInHand-active.hand.count, drawn: 0, context: context)
    }

    private func getCards(needed: Int, drawn: Int, context: BuildersBoard) -> EventLoopFuture<()> {
        guard drawn < needed else { return context.runLoop.newSucceededFuture(result: ()) }

        let active: BuilderPlayer = context.activePlayer

        return active.getInput(
                UserInteraction(type: .turn,
                                interaction: BuildersInteraction(phase: .draw, dialog: [
                                    "Draw:",
                                    "1: Worker",
                                    "2: Material",
                                    "3: Accident"
                                ]))).then {response -> EventLoopFuture<()> in
            guard case let .draw(drawType) = response else {
                return self.getCards(needed: needed, drawn: drawn, context: context)
            }

            switch drawType {
            case .worker:
                active.hand.append(Worker.getInstance())
            case .material:
                active.hand.append(Material.getInstance())
            case .accident:
                active.hand.append(Accident.getInstance())
            }

            return self.getCards(needed: needed, drawn: drawn + 1, context: context)
        }
    }
}

/// The last phase in a turn. This does any cleanup to put the context in a good state for the next player.
struct EndPhase : BuilderPhase {
    private(set) weak var context: BuildersBoard?

    func doPhase() -> EventLoopFuture<()> {
        guard let context = context else { return deadGame }

        let active = context.activePlayer

        active.send(UserInteraction(type: .turnEnd, interaction: BuildersInteraction()))

        // Go through all active accidents increment the turn
        context.accidents[active] = context.accidents[active, default: []].map({accident in
            return Accident(type: accident.type, turns: accident.turns + 1)
        })

        return context.runLoop.newSucceededFuture(result: ())
    }

    static func ~~> (lhs: EventLoopFuture<BuilderPhase>, rhs: EndPhase) -> EventLoopFuture<()> {
        return lhs.then {phase in
            return phase.doPhase().then({_ in rhs.doPhase() })
        }
    }
}