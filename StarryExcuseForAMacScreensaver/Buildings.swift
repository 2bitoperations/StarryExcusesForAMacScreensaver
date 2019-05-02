//
//  BuildingStyles.swift
//  StarryExcusesForAMacScreensaver
//
//  Created by Andrew Malota on 2019-04-29
//  forked from Marcus Kida's work https://github.com/kimar/DeveloperExcuses
//  port of Evan Green's implementation for Windows https://github.com/evangreen/starryn
//  released under the MIT license
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
    
    init(width: Int, height: Int, startX: Int, startY: Int, zCoordinate: Int, style: BuildingStyle) throws {
        if (width <= 0) {
            throw StateError.ConstraintViolation(msg: "width can't be less than or equal to zero - \(width) is invalid")
        }
        if (height <= 0) {
            throw StateError.ConstraintViolation(msg: "height can't be less than or equal to zero - \(height) is invalid")
        }
        self.width = width
        self.height = height
        self.startX = startX
        self.startY = startY
        self.zCoordinate = zCoordinate
        self.style = style
    }
    
    func isPixelInsideBuilding(screenXPos: Int, screenYPos: Int) -> Bool {
        return (startX <= screenXPos) && (screenXPos < (startX + width))
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

