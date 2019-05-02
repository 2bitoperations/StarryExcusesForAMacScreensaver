//
//  Points.swift
//  StarryExcusesForAMacScreensaver
//
//  Created by Andrew Malota on 2019-04-29
//  forked from Marcus Kida's work https://github.com/kimar/DeveloperExcuses
//  port of Evan Green's implementation for Windows https://github.com/evangreen/starryn
//  released under the MIT license
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
