//
//  CGContext.swift
//  StarryExcusesForAMacScreensaver
//
//  Created by Andrew Malota on 4/29/19.
//  Copyright © 2019 2bitoperations. All rights reserved.
//

import Foundation


extension CGContext{
    func protectGState(_ drawStuff: () -> Void) {
        saveGState()
        drawStuff()
        restoreGState()
    }
}
