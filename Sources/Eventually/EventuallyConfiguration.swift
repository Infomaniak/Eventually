//
//  Created by Mikalai Zmachynski.
//  Copyright © 2026 Mikalai Zmachynski. All rights reserved.
//

import Foundation

public struct EventuallyConfiguration: Sendable {
    public let hSpacing: CGFloat
    public let hPadding: CGFloat

    public let vSpacing: CGFloat

    // the layout ensures event titles remain visible
    public let titleHeight: CGFloat
    public let minEventWidth: CGFloat
    public let minEventHeight: CGFloat

    public init(
        hSpacing: CGFloat = 1,
        hPadding: CGFloat = 14,
        vSpacing: CGFloat = 0,
        titleHeight: CGFloat = 20,
        minEventWidth: CGFloat = 4,
        minEventHeight: CGFloat = 16
    ) {
        self.hSpacing = hSpacing
        self.hPadding = hPadding
        self.vSpacing = vSpacing
        self.titleHeight = titleHeight
        self.minEventWidth = minEventWidth
        self.minEventHeight = minEventHeight
    }
}
