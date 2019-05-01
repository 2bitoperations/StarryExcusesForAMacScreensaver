//
//  Skyline.swift
//  StarryExcusesForAMacScreensaver
//
//  Created by Andrew Malota on 4/29/19.
//  Copyright © 2019 2bitoperations. All rights reserved.
//

import Foundation
import os

class Skyline {
    // list of buildings on the screen, sorted by startX coordinate
    let buildings: [Building]
    let width: Int
    let height: Int
    let starsPerUpdate: Int
    let buildingLightsPerUpdate: Int
    let buildingMaxHeight: Int
    let buildingColor: Color
    let log: OSLog
    
    init(screenXMax: Int,
         screenYMax: Int,
         buildingHeightPercentMax: Double = 0.35,
         buildingWidthMin: Int = 5,
         buildingWidthMax: Int = 18,
         buildingCount: Int = 100,
         starsPerUpdate: Int = 12,
         buildingLightsPerUpdate: Int = 15,
         buildingColor: Color = Color(red: 0.972, green: 0.945, blue: 0.012)) {
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
        var buildingWorkingList = [Building]()
        self.width = screenXMax
        self.height = screenYMax
        self.starsPerUpdate = starsPerUpdate
        self.buildingLightsPerUpdate = buildingLightsPerUpdate
        let styles = BuildingStyle.getBuildingStyles()
        self.buildingMaxHeight = Int(Double(screenYMax) * buildingHeightPercentMax)
        self.buildingColor = buildingColor
        
        os_log("invoking skyline init, screen %{PUBLIC}dx%{PUBLIC}d", log: log, type: .fault, screenXMax, screenYMax)
        
        os_log("found %{PUBLIC}d styles",
               log: log,
               type: .fault,
               styles.count)
        
        for buildingZIndex in 0...buildingCount {
            os_log("building a building", log: log, type: .debug)
            // pick a style
            let style = styles[Int.random(in: 0...styles.count - 1)]
            
            // squaring the building height evidently yeilds better looking
            // skylines
            let height = Skyline.getWeightedRandomHeight(maxHeight: buildingMaxHeight)
            
            let buildingXStart = Int.random(in: 0...screenXMax - 1)
            
            let building = Building(width: Int.random(in: buildingWidthMin...buildingWidthMax-1),
                                    height: height,
                                    startX: buildingXStart,
                                    startY: 0,
                                    zCoordinate: buildingZIndex,
                                    style: style)
            os_log("created building at %{public}d, width %{public}d, height %{public}d",
                   log: log,
                   type: .fault,
                   building.startX,
                   building.width,
                   building.height)
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
            os_log("generated single star at %{public}dx%{public}d",
                   log: log,
                   type: .info,
                   screenXPos,
                   screenYPos)
        } while (getBuildingAtPoint(screenXPos: screenXPos, screenYPos: screenYPos) != nil)
        let color = Color(red: Double.random(in: 0.0...0.5),
                          green: Double.random(in: 0.0...0.5),
                          blue: Double.random(in: 0.0...1))
        os_log("returning single star at %{public}dx%{public}d, color r:%{public}f, g:%{public}f, b:%{public}f",
               log: log,
               type: .info,
               screenXPos,
               screenYPos,
               color.red,
               color.green,
               color.blue)
        return Point(xPos: screenXPos,
                     yPos: screenYPos,
                     color: color)
    }
    
    func getSingleBuildingPoint() -> Point {
        var screenYPos: Int
        var screenXPos: Int
        var buildingAtPos: Building?
        repeat {
            screenYPos = Skyline.getWeightedRandomHeight(maxHeight: self.buildingMaxHeight)
            screenXPos = Int.random(in: 0...self.width-1)
            buildingAtPos = getBuildingAtPoint(screenXPos: screenXPos,
                                               screenYPos: screenYPos)
            os_log("checking light at %{public}@x%{public}@",
                   log: log,
                   type: .fault,
                   screenXPos,
                   screenYPos)
        } while (buildingAtPos?.isLightOn(screenXPos: screenYPos,
                                          screenYPos: screenXPos) ?? false)
        
        os_log("returning light at %{public}dx%{public}d",
               log: log,
               type: .fault,
               screenXPos,
               screenYPos)
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
