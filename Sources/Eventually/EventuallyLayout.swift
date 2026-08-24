//
//  Created by Mikalai Zmachynski.
//  Copyright © 2026 Mikalai Zmachynski. All rights reserved.
//

import SwiftUI

/**
 The rules, that aligned events must follow:
 - Top and Bottom position of event is explicitely defined by start/end date.
 - Left position and width are flexible and modified to fit the layout.
 - Event tries to occupy the widest possible area.
 - Events are placed side by side and do not intersect if their title areas overlap.
 - Event frame cannot intersect the left edge of any other event.

 The layout process algoritm:
 1. Events are sorted by date and duration.
 2. Align events from oldest to newest. Older events alignment impact on newer events alignment. But not the other way around. Aligned events remain untouched.
 3. Iterate sorted events one by one. Set initial frame for an event: minY/maxY defined by event start/end date, width = container width.
 4. Find a group of events that should be aligned side by side (these are events which title areas overlap). This group is called HStack.
 5. Make a union of all the rects in the HStack (combined frame).
 6. Find the intersection of the combined frame with left edges of all the previously aligned events.
 7. Split the combined rect into smaller frames, divided by intersections.
 8. Spread events in HStack among the frames. Event must try to occupy the widest area.
 9. Store calculated event frames.
 10. Events in HStack are aligned. Now reset the HStack and repeat steps 4-10.
 */
public struct EventuallyLayout: Layout {
    public struct Cache {
        var frames: [Int: CGRect]?
        var layoutWidth: CGFloat?
        var horizontalHourSlotHeight: CGFloat?

        var orderedIndices: [Int] = []
        var coveredTextHeights: [Int: CGFloat] = [:]
        var reportTask: Task<Void, Never>?
    }

    // This must be the beginning of date to display. 00:00:00 in local time
    // This parameter cannot be infered from events, because event can start and end of a different date.
    private let startOfDay: Date
    // The height of one hour slot on a timeline (in points).
    private let hourSlotHeight: CGFloat
    private let horizontalHourSlotHeight: CGFloat
    private let config: EventuallyConfiguration
    private let onCoveredIndicesChange:
        @MainActor @Sendable ([Int: CGFloat]) -> Void

    public init(
        startOfDay: Date,
        hourSlotHeight: CGFloat,
        horizontalHourSlotHeight: CGFloat? = nil,
        config: EventuallyConfiguration = .init(),
        onCoveredIndicesChange:
        @escaping @MainActor @Sendable ([Int: CGFloat]) -> Void = { _ in }
    ) {
        self.startOfDay = startOfDay
        self.hourSlotHeight = hourSlotHeight
        self.horizontalHourSlotHeight =
            horizontalHourSlotHeight ?? hourSlotHeight
        self.config = config
        self.onCoveredIndicesChange = onCoveredIndicesChange
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews _: Subviews,
        cache _: inout Cache
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    public func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let eventIntervals = subviews.map {
            $0[EventuallyLayoutKey.self]
        }

        let layoutWidth = proposal
            .replacingUnspecifiedDimensions()
            .width

        let widthTolerance = 0.5
        let widthChanged = cache.layoutWidth.map {
            abs($0 - layoutWidth) > widthTolerance
        } ?? true

        if cache.frames == nil
            || widthChanged
            || cache.horizontalHourSlotHeight != horizontalHourSlotHeight {
            calculateLayout(
                proposal: proposal,
                subviews: subviews,
                cache: &cache
            )
        }

        guard let cachedFrames = cache.frames else {
            return
        }

        let liveFrames = makeLiveFrames(
            cachedFrames: cachedFrames,
            eventIntervals: eventIntervals
        )

        for (index, subview) in subviews.enumerated() {
            guard let frame = liveFrames[index] else {
                continue
            }
            let size = ProposedViewSize(frame.size)
            subview.place(at: CGPoint(
                // placeSubviews is called several times with the same proposal, but different bounds.
                // So do not store bounds.minX, bounds.minY in cache
                x: bounds.minX + frame.minX,
                y: bounds.minY + frame.minY
            ), proposal: size)
        }

        calculateCoveredTextHeights(
            frames: liveFrames,
            orderedIndices: cache.orderedIndices,
            cache: &cache
        )
    }

    private func calculateLayout(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        cache.orderedIndices = []
        cache.frames = [:]
        cache.layoutWidth = proposal.replacingUnspecifiedDimensions().width
        cache.horizontalHourSlotHeight = horizontalHourSlotHeight

        guard !subviews.isEmpty else {
            if cache.coveredTextHeights != [:] {
                cache.coveredTextHeights = [:]
                Task { @MainActor in
                    onCoveredIndicesChange([:])
                }
            }
            return
        }

        let layoutSize = proposal.replacingUnspecifiedDimensions()
        let titleHeightInSeconds = 3600 / horizontalHourSlotHeight * config.titleHeight
        let pointsPerSecond = horizontalHourSlotHeight / 3600
        let fullHeight = 24 * 3600 * pointsPerSecond

        let sortedSubviews = subviews.enumerated().sorted { first, second in
            guard
                let firstInterval = first.1[EventuallyLayoutKey.self],
                let secondInterval = second.1[EventuallyLayoutKey.self]
            else {
                return false
            }

            let delta = abs(secondInterval.start.timeIntervalSince(firstInterval.start))
            return delta < titleHeightInSeconds
                ? firstInterval.duration > secondInterval.duration
                : firstInterval.start < secondInterval.start
        }

        cache.orderedIndices = sortedSubviews.map { $0.offset }

        var eventFrames = [CGRect]()
        var hStackStartIndex = 0
        let totalElementsCount = sortedSubviews.count
        for index in 0 ... totalElementsCount {
            let isLastElement = index == totalElementsCount
            var eventRect: CGRect?
            let shouldProcessHStack: Bool

            defer {
                if let eventRect {
                    eventFrames.append(eventRect)
                }
            }

            if !isLastElement {
                let subview = sortedSubviews[index].1
                guard
                    let interval = subview[EventuallyLayoutKey.self]
                else {
                    continue
                }

                let localStartDate = max(interval.start, startOfDay)
                let localInterval = DateInterval(start: localStartDate, end: max(interval.end, startOfDay))
                let originY = CGFloat(localStartDate.timeIntervalSince(startOfDay)) * pointsPerSecond
                let maxHeight = fullHeight - originY
                // round it down so fractional values do not accidentally intersect, and -1 to make a padding between vertical events
                let height = max(min(localInterval.duration * pointsPerSecond, maxHeight), config.minEventHeight).rounded(to: 2, rule: .down) - 1
                eventRect = CGRect(
                    x: 0,
                    y: originY,
                    width: layoutSize.width,
                    height: height
                )

                let delta = index != 0 ? originY - eventFrames[hStackStartIndex].origin.y : 0
                shouldProcessHStack = delta > config.titleHeight
            } else {
                shouldProcessHStack = true
            }

            guard shouldProcessHStack else {
                continue
            }

            // This rect takes full layout width, vertical position and height is a union of events positions and heights in a stack.
            // It is used to get intersections with previous events and form a set of frames where events can be placed.
            let combinedHStackRect = (hStackStartIndex ..< eventFrames.count).reduce(
                into: eventFrames[hStackStartIndex]
            ) { result, index in
                result = result.union(eventFrames[index])
            }

            // find all X coordinates that intersects combinedHStackRect and splits it into frame containers
            // add the layout left edge
            var intersectedOrigins: [CGPoint] = [combinedHStackRect.origin]
            if hStackStartIndex > 0 {
                for eventIndex in 0 ..< hStackStartIndex {
                    var rect = eventFrames[eventIndex]
                    rect.origin.y += config.titleHeight
                    rect.size.height -= config.titleHeight
                    if rect.intersects(combinedHStackRect) {
                        let intersection = rect.intersection(combinedHStackRect)
                        intersectedOrigins.append(intersection.origin)
                    }
                }
            }
            // add the layout right edge
            intersectedOrigins.append(CGPoint(x: layoutSize.width, y: 0))
            intersectedOrigins.sort { $0.x < $1.x }

            // event frames must fit into frame containers
            var frameContainers = [CGRect]()
            var frameHPaddings = [CGFloat]()
            for i in 0 ..< (intersectedOrigins.count - 1) {
                if (intersectedOrigins[i].x + config.hPadding) < intersectedOrigins[i + 1].x {
                    frameContainers.append(CGRect(
                        origin: intersectedOrigins[i],
                        size: CGSize(
                            width: intersectedOrigins[i + 1].x - intersectedOrigins[i].x,
                            height: combinedHStackRect.height
                        )
                    ))
                    frameHPaddings.append(frameContainers.count == 1 && i == 0 ? 0 : config.hPadding)
                }
            }

            // if no appropriate containers where created, create an empty one. We still must call `subview.place`
            // with .zero rect for invisible events
            if frameContainers.isEmpty {
                frameContainers = [.zero]
                frameHPaddings = [0]
            }

            // Distrubute events among frame containers
            var frameEvents = [Int: [Int]]() // [frame index: [event index]]
            for eventIndex in hStackStartIndex ..< eventFrames.count {
                let eventRect = eventFrames[eventIndex]
                var currentWidth: CGFloat = 0
                var currentFrameIndex = 0
                for (frameIndex, frame) in frameContainers.enumerated() {
                    // float numbers may differ in a very small fraction like 0.000000000001
                    // this may impact where event rect will be placed.
                    let frame = frame.rounded(to: 2)
                    let frameHPadding = frameHPaddings[frameIndex]
                    let frameAvailableWidth = (frame.width - frameHPadding) / CGFloat(frameEvents[frameIndex, default: []].count + 1)
                    if
                        eventRect.minY >= frame.minY,
                        eventRect.minY <= frame.maxY,
                        currentWidth < frameAvailableWidth
                    {
                        currentWidth = frameAvailableWidth
                        currentFrameIndex = frameIndex
                    }
                }
                frameEvents[currentFrameIndex, default: []].append(eventIndex)
            }

            for (frameIndex, eventIndices) in frameEvents {
                let frame = frameContainers[frameIndex]
                let frameHPadding = frameHPaddings[frameIndex]
                let eventWidth = max((frame.width - frameHPadding) / CGFloat(eventIndices.count), config.minEventWidth)
                for (i, eventIndex) in eventIndices.enumerated() {
                    let originX = frame.minX + eventWidth * CGFloat(i) + frameHPadding
                    var eventRect = eventFrames[eventIndex]

                    // if the final event frame does not fit the container frame, then just collapse the final frame
                    // so it is not visible and does not affect the layout of other events
                    if originX + eventWidth > frame.maxX {
                        eventRect.size = .zero
                        eventRect.origin = .zero
                    } else {
                        eventRect.size.width = eventWidth
                        eventRect.origin.x = originX
                    }
                    eventFrames[eventIndex] = eventRect

                    let finalFrame = CGRect(
                        origin: eventRect.origin,
                        size: CGSize(
                            width: max(eventRect.size.width - config.hSpacing, 0),
                            height: eventRect.size.height
                        )
                    )

                    cache.frames?[sortedSubviews[eventIndex].0] = finalFrame
                }
            }

            hStackStartIndex = index
        }
    }

    // Keeps the cached x/width and replaces only y/height with the live scale.
    private func makeLiveFrames(
        cachedFrames: [Int: CGRect],
        eventIntervals: [DateInterval?]
    ) -> [Int: CGRect] {
        let pointsPerSecond = hourSlotHeight / 3600
        let fullHeight = 24 * 3600 * pointsPerSecond
        var liveFrames = [Int: CGRect]()

        for (index, cachedFrame) in cachedFrames {
            guard
                !cachedFrame.isEmpty,
                eventIntervals.indices.contains(index),
                let interval = eventIntervals[index]
            else {
                liveFrames[index] = .zero
                continue
            }

            let localStartDate = max(interval.start, startOfDay)
            let localInterval = DateInterval(
                start: localStartDate,
                end: max(interval.end, startOfDay)
            )
            let originY = CGFloat(
                localStartDate.timeIntervalSince(startOfDay)
            ) * pointsPerSecond
            let maxHeight = fullHeight - originY
            let height = max(
                min(localInterval.duration * pointsPerSecond, maxHeight),
                config.minEventHeight
            )
            .rounded(to: 2, rule: .down) - 1

            liveFrames[index] = CGRect(
                x: cachedFrame.minX,
                y: originY,
                width: cachedFrame.width,
                height: height
            )
        }

        return liveFrames
    }

    private func calculateCoveredTextHeights(
        frames: [Int: CGRect],
        orderedIndices: [Int],
        cache: inout Cache
    ) {
        var coveredTextHeights: [Int: CGFloat] = [:]

        for (position, lowerIndex) in orderedIndices.enumerated() {
            guard
                let lowerFrame = frames[lowerIndex],
                !lowerFrame.isEmpty
            else {
                continue
            }

            var minCoveringY: CGFloat?

            for upperIndex in orderedIndices.dropFirst(position + 1) {
                guard
                    let upperFrame = frames[upperIndex],
                    !upperFrame.isEmpty
                else {
                    continue
                }

                let intersection = lowerFrame.intersection(upperFrame)

                guard
                    !intersection.isNull,
                    intersection.width > 1,
                    intersection.height > 1
                else {
                    continue
                }

                let coveringY =
                    upperFrame.minY - lowerFrame.minY

                if coveringY > 0 {
                    minCoveringY = min(
                        minCoveringY ?? coveringY,
                        coveringY
                    )
                }
            }

            if let minCoveringY {
                coveredTextHeights[lowerIndex] = minCoveringY
            }
        }

        if cache.coveredTextHeights != coveredTextHeights {
            cache.coveredTextHeights = coveredTextHeights

            cache.reportTask?.cancel()

            cache.reportTask = Task { @MainActor [coveredTextHeights] in
                guard !Task.isCancelled else {
                    return
                }

                onCoveredIndicesChange(coveredTextHeights)
            }
        }
    }
}
