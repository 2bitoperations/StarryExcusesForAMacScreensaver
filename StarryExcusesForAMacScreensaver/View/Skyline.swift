//
//  Skyline.swift
//  StarryExcusesForAMacScreensaver
//
//  Created by Andrew Malota on 4/29/19.
//  Copyright © 2019 2bitoperations. All rights reserved.
//

import Foundation

class Skyline {
    // list of buildings on the screen, sorted by startX coordinate
    let buildings: [Building]
    let width: Int
    let height: Int
    let starsPerUpdate: Int
    let buildingLightsPerUpdate: Int
    let buildingMaxHeight: Int
    let buildingColor: Color
    
    init(screenXMax: Int,
         screenYMax: Int,
         buildingHeightPercentMax: Double = 0.35,
         buildingWidthMin: Int = 5,
         buildingWidthMax: Int = 18,
         buildingCount: Int = 100,
         starsPerUpdate: Int = 12,
         buildingLightsPerUpdate: Int = 15,
         buildingColor: Color = Color(red: 0.972, green: 0.945, blue: 0.012)) {
        var buildingWorkingList = [Building]()
        self.width = screenXMax
        self.height = screenYMax
        self.starsPerUpdate = starsPerUpdate
        self.buildingLightsPerUpdate = buildingLightsPerUpdate
        let styles = BuildingStyle.getBuildingStyles()
        self.buildingMaxHeight = Int(Double(screenYMax) * buildingHeightPercentMax)
        self.buildingColor = buildingColor
        
        for buildingZIndex in 0...buildingCount {
            // pick a style
            let style = styles[Int.random(in: 0...styles.count)]
            
            // squaring the building height evidently yeilds better looking
            // skylines
            let height = Skyline.getWeightedRandomHeight(maxHeight: buildingMaxHeight)
            
            let buildingXStart = Int.random(in: 0...screenXMax)
            
            let building = Building(width: Int.random(in: buildingWidthMin...buildingWidthMax),
                                    height: height,
                                    startX: buildingXStart,
                                    startY: 0,
                                    zCoordinate: buildingZIndex,
                                    style: style)
            buildingWorkingList.append(building)
        }
        
        buildings = buildingWorkingList.sorted(by: { (a:Building, b:Building) -> Bool in
            return a.zCoordinate > b.zCoordinate
        })
    }
    
    static func getWeightedRandomHeight(maxHeight: Int) -> Int {
        let weightedHeightPercentage = pow(Double.random(in: 0...1),2)
        return Int(weightedHeightPercentage * Double(maxHeight))
    }
    
    func getSingleStar() -> Point {
        var screenYPos: Int
        var screenXPos: Int
        repeat {
            screenYPos = Skyline.getWeightedRandomHeight(maxHeight: self.height)
            screenXPos = Int.random(in: 0...self.width)
        } while (getBuildingAtPoint(screenXPos: screenXPos, screenYPos: screenYPos) != nil)
        return Point(xPos: screenXPos,
                     yPos: screenYPos,
                     color: Color(red: Double.random(in: 0.0...0.5),
                         green: Double.random(in: 0.0...0.5),
                         blue: Double.random(in: 0.0...1)))
    }
    
    func getSingleBuildingPoint() -> Point {
        var screenYPos: Int
        var screenXPos: Int
        var buildingAtPos: Building?
        repeat {
            screenYPos = Skyline.getWeightedRandomHeight(maxHeight: self.buildingMaxHeight)
            screenXPos = Int.random(in: 0...self.width)
            buildingAtPos = getBuildingAtPoint(screenXPos: screenXPos,
                                                  screenYPos: screenYPos)
        } while (buildingAtPos?.isLightOn(screenXPos: screenYPos,
                                          screenYPos: screenXPos) ?? false)
        
        return Point(xPos: screenXPos,
                     yPos: screenYPos,
                     color: buildingColor)
    }
    
    func getBuildingAtPoint(screenXPos: Int, screenYPos: Int) -> Building? {
        var frontBuilding: Building?
        for building in self.buildings {
            
            // The buildings are sorted by X coordinate. If this building starts
            // to the right of the pixel in question, none of the rest intersect.
            if building.startX > screenXPos {
                break
            }
            
            // Is the pixel inside this building?
            if building.isPixelInsideBuilding(screenXPos: screenXPos,
                                              screenYPos: screenYPos) {
                // and is this building the current frontmost building?
                if let oldLeader = frontBuilding {
                    if (building.zCoordinate > oldLeader.zCoordinate) {
                        frontBuilding = building
                    }
                } else {
                    frontBuilding = building
                }
            }
        }
        
        return frontBuilding
    }
}
