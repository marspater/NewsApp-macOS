// Copyright 2026 Mars Pater
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Where keyboard focus goes in the Today edition (docs/design/today.md, "Keyboard focus"; #936): left and right
/// inside a lane, up and down between lanes, J and K through the page in reading order, and where focus lands when
/// the edition changes under it. Pure, so the rules are tested without a window.
struct TodayFocusMap: Equatable, Sendable {
    struct Lane: Equatable, Sendable {
        let lane: TodayLane
        let ids: [String]
        /// Cards per row. A lane row is one row of any length (0); The Latest is a grid, or a list of one column.
        var columns = 0
    }

    enum Direction: Sendable { case left, right, up, down }

    /// The lanes that hold cards, in page order.
    let lanes: [Lane]

    init(lanes: [Lane]) {
        self.lanes = lanes.filter { !$0.ids.isEmpty }
    }

    /// Every card in reading order: through each row, then the next lane.
    var readingOrder: [String] { lanes.flatMap(\.ids) }

    func position(of id: String?) -> (lane: Int, index: Int)? {
        guard let id else { return nil }
        for (laneIndex, lane) in lanes.enumerated() {
            if let index = lane.ids.firstIndex(of: id) { return (laneIndex, index) }
        }
        return nil
    }

    func lane(of id: String?) -> TodayLane? {
        position(of: id).map { lanes[$0.lane].lane }
    }

    /// J and K: the next or previous story in reading order, stopping at the ends. Without focus, the first story,
    /// or the last when moving back.
    func step(_ offset: Int, from id: String?) -> String? {
        let order = readingOrder
        guard !order.isEmpty else { return nil }
        guard let id, let index = order.firstIndex(of: id) else { return offset > 0 ? order.first : order.last }
        return order[max(0, min(order.count - 1, index + offset))]
    }

    /// An arrow key. `memory` is each lane's last focused card; a lane entered from above or below gives focus to
    /// it, else to the card at its leading edge on screen, else to its first card.
    /// `visible` is each lane's leading card on screen, taken when the lane has no remembered card.
    func move(
        _ direction: Direction, from id: String?, memory: [TodayLane: String] = [:], visible: [TodayLane: String] = [:]
    ) -> String? {
        guard let (laneIndex, index) = position(of: id) else { return lanes.first?.ids.first }
        let lane = lanes[laneIndex]
        let rows = lane.columns > 0
        switch direction {
        case .left:
            // The Lead is a loop; a row and the grid stop at their ends.
            if lane.lane == .theLead { return lane.ids[(index - 1 + lane.ids.count) % lane.ids.count] }
            return lane.ids[max(0, index - 1)]
        case .right:
            if lane.lane == .theLead { return lane.ids[(index + 1) % lane.ids.count] }
            return lane.ids[min(lane.ids.count - 1, index + 1)]
        case .up:
            if rows, index - lane.columns >= 0 { return lane.ids[index - lane.columns] }
            return entry(toLane: laneIndex - 1, memory: memory, visible: visible) ?? id
        case .down:
            if rows {
                if index + lane.columns < lane.ids.count { return lane.ids[index + lane.columns] }
                // A shorter last row: the card below is missing, so the row's last card takes focus.
                let lastRowStart = (lane.ids.count - 1) / lane.columns * lane.columns
                return index < lastRowStart ? lane.ids[lane.ids.count - 1] : id
            }
            return entry(toLane: laneIndex + 1, memory: memory, visible: visible) ?? id
        }
    }

    private func entry(toLane index: Int, memory: [TodayLane: String], visible: [TodayLane: String]) -> String? {
        guard lanes.indices.contains(index) else { return nil }
        let lane = lanes[index]
        if let remembered = memory[lane.lane], lane.ids.contains(remembered) { return remembered }
        if let leading = visible[lane.lane], lane.ids.contains(leading) { return leading }
        return lane.ids.first
    }

    /// Where focus lands after the edition changed from `old` to this one:
    /// - a card still in the edition keeps focus, also in another lane;
    /// - a card gone from a lane that remains passes focus to the card at its index, or the lane's last card;
    /// - a lane gone passes focus to the first card of the next lane below that holds cards, else to the last card
    ///   of the nearest lane above; with no card left, nothing holds focus.
    func restoredFocus(_ id: String?, from old: TodayFocusMap) -> String? {
        guard let id else { return nil }
        if position(of: id) != nil { return id }
        guard let (oldLaneIndex, index) = old.position(of: id) else { return nil }
        let gone = old.lanes[oldLaneIndex].lane
        if let lane = lanes.first(where: { $0.lane == gone }) { return lane.ids[min(index, lane.ids.count - 1)] }
        let pageOrder = TodayLane.displayOrder
        guard let place = pageOrder.firstIndex(of: gone) else { return lanes.first?.ids.first }
        if let below = lanes.first(where: { (pageOrder.firstIndex(of: $0.lane) ?? 0) > place }) {
            return below.ids.first
        }
        return lanes.last(where: { (pageOrder.firstIndex(of: $0.lane) ?? 0) < place })?.ids.last
    }
}
