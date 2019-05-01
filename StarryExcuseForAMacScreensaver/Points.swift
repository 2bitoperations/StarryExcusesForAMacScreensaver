//
//  Points.swift
//  StarryExcusesForAMacScreensaver
//
//  Created by Andrew Malota on 4/29/19.
//  Copyright © 2019 2bitoperations. All rights reserved.
//

import Foundation

struct Point {
    let xPos: Int
    let yPos: Int
    let color: Color
    
    init(xPos: Int, yPos: Int, color: Color) {
        self.xPos = xPos
        self.yPos = yPos
        self.color = color
    }
}

struct Color {
    let red, green, blue: Double
    
    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}
