//
//  BuildingStyles.swift
//  StarryExcusesForAMacScreensaver
//
//  Created by Andrew Malota on 4/29/19.
//  Copyright © 2019 2bitoperations. All rights reserved.
//

import Foundation

struct BuildingStyle {
    var styleTiles = [[Int]]()
    
    static func getBuildingStyles () -> [BuildingStyle] {
        var styles = [BuildingStyle]()
        styles.append(BuildingStyle(styleTiles: [
            [0, 0, 0, 0, 1, 0, 0, 1],
            [0, 0, 0, 0, 1, 0, 0, 1],
            [0, 0, 0, 0, 1, 0, 0, 1],
            [0, 0, 0, 0, 1, 0, 0, 1],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0]]))
        styles.append(BuildingStyle(styleTiles: [
            [1, 1, 0, 0, 1, 1, 0, 0],
            [1, 1, 0, 0, 1, 1, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0]]))
        styles.append(BuildingStyle(styleTiles: [
            [1, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0]]))
        styles.append(BuildingStyle(styleTiles: [
            [0, 1, 0, 1, 0, 1, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0]]))
        styles.append(BuildingStyle(styleTiles: [
            [1, 0, 0, 0, 1, 0, 0, 0],
            [1, 0, 0, 0, 1, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [1, 0, 0, 0, 1, 0, 0, 0],
            [1, 0, 0, 0, 1, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0]]))
        styles.append(BuildingStyle(styleTiles: [
            [0, 1, 1, 0, 1, 1, 0, 0],
            [0, 1, 1, 0, 1, 1, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0]]))
        return styles
    }
}

class Building {
    let width: Int
    let height: Int
    let startX: Int
    let startY: Int
    let zCoordinate: Int
    let style: BuildingStyle
    
    init(width: Int, height: Int, startX: Int, startY: Int, zCoordinate: Int, style: BuildingStyle) {
        self.width = width
        self.height = height
        self.startX = startX
        self.startY = startY
        self.zCoordinate = zCoordinate
        self.style = style
    }
    
    func isPixelInsideBuilding(screenXPos: Int, screenYPos: Int) -> Bool {
        return (startX <= screenXPos) && (screenYPos < (startX + width))
            && (startY <= screenYPos) && (screenYPos < (startY + height))
    }
    
    func isLightOn(screenXPos: Int, screenYPos: Int) -> Bool {
        if !self.isPixelInsideBuilding(screenXPos: screenXPos,
                                       screenYPos: screenYPos) {
            return false
        }
        
        let xTileIndex = (screenXPos - startX) % (style.styleTiles[0].count)
        let yTileIndex = (screenYPos - startY) % (style.styleTiles.count)
        
        return style.styleTiles[yTileIndex][xTileIndex] == 1
    }
}

