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
    let flasherRadius: Int
    let flasherPeriod: TimeInterval
    var flasherPosition: Point?
    var flasherOnAt: NSDate
    
    init(screenXMax: Int,
         screenYMax: Int,
         buildingHeightPercentMax: Double = 0.35,
         buildingWidthMin: Int = 40,
         buildingWidthMax: Int = 300,
         buildingCount: Int = 100,
         starsPerUpdate: Int = 12,
         buildingLightsPerUpdate: Int = 15,
         buildingColor: Color = Color(red: 0.972, green: 0.945, blue: 0.012),
         flasherRadius: Int = 4,
         flasherPeriod: TimeInterval = TimeInterval(2.0),
         log: OSLog) {
        self.log = log
        var buildingWorkingList = [Building]()
        self.width = screenXMax
        self.height = screenYMax
        self.starsPerUpdate = starsPerUpdate
        self.buildingLightsPerUpdate = buildingLightsPerUpdate
        let styles = BuildingStyle.getBuildingStyles()
        self.buildingMaxHeight = Int(Double(screenYMax) * buildingHeightPercentMax)
        self.buildingColor = buildingColor
        self.flasherRadius = flasherRadius
        self.flasherPeriod = flasherPeriod
        self.flasherOnAt = NSDate()
        
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
            buildingWorkingList.append(building)
        }
        
        buildings = buildingWorkingList.sorted(by: { (a:Building, b:Building) -> Bool in
            return a.startX < b.startX
        })
        
        for building in buildings {
            os_log("created building at %{public}d, width %{public}d, height %{public}d",
                   log: log,
                   type: .fault,
                   building.startX,
                   building.width,
                   building.height)
        }
        
        self.flasherPosition = getFlasherPosition()
    }
    
    static func getWeightedRandomHeight(maxHeight: Int) -> Int {
        let weightedHeightPercentage = pow(Double.random(in: 0...1),2)
        return Int(weightedHeightPercentage * Double(maxHeight))
    }
    
    func getSingleStar() -> Point {
        var screenYPos: Int
        var screenXPos: Int
        var triesBeforeNoCollision = 0;
        
        repeat {
            triesBeforeNoCollision += 1
            screenYPos = Skyline.getWeightedRandomHeight(maxHeight: self.height)
            screenXPos = Int.random(in: 0...self.width)
        } while (getBuildingAtPoint(screenXPos: screenXPos, screenYPos: screenYPos) != nil)
        let color = Color(red: Double.random(in: 0.0...0.5),
                          green: Double.random(in: 0.0...0.5),
                          blue: Double.random(in: 0.0...1))
        os_log("returning single star at %{public}dx%{public}d, color r:%{public}f, g:%{public}f, b:%{public}f, tries %{public}d",
               log: log,
               type: .info,
               screenXPos,
               screenYPos,
               color.red,
               color.green,
               color.blue,
               triesBeforeNoCollision)
        return Point(xPos: screenXPos,
                     yPos: screenYPos,
                     color: color)
    }
    
    func getSingleBuildingPoint() -> Point {
        var screenYPos = 0
        var screenXPos = 0
        var buildingAtPos: Building?
        var lightOn = false
        var tries = 0;
        
        while (buildingAtPos == nil || !lightOn) {
            tries += 1
            
            screenXPos = Int.random(in: 0...self.width-1)
            screenYPos = Int.random(in: 0...self.height-1)
            buildingAtPos = getBuildingAtPoint(screenXPos: screenXPos,
                                               screenYPos: screenYPos)
            if (buildingAtPos != nil) {
                lightOn = (buildingAtPos?.isLightOn(screenXPos: screenXPos, screenYPos: screenYPos))!
            }
        }
        
        os_log("returning light at %{public}dx%{public}d after %{public}d tries",
               log: log,
               type: .fault,
               screenXPos,
               screenYPos,
               tries)
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
    
    func getTallestBuilding() -> Building? {
        var currentTallest: Building?
        for building in buildings {
            if (currentTallest == nil || building.height > currentTallest!.height) {
                currentTallest = building
            }
        }
        
        return currentTallest
    }
    
    private func getFlasherPosition() -> Point? {
        // find the tallest building
        let tallestBuilding = getTallestBuilding()
        guard let building = tallestBuilding else {
            os_log("flasher not enabled, no buildings.",
                   log: log,
                   type: .fault)
            return nil
        }
        
        let flasherXLoc = building.startX + (building.width / 2)
        let flasherYLoc = building.startY + building.height + flasherRadius
        
        os_log("flasher enabled at %{public}dx%{public}d r=%{public}d",
               log: log,
               type: .fault,
               flasherXLoc,
               flasherYLoc,
               flasherRadius)
        
        return Point(xPos: flasherXLoc, yPos: flasherYLoc, color: Color(red: 1.0, green: 0.0, blue: 0.0))
    }
    
    func getFlasher() -> Point? {
        guard let flasherPosition = self.flasherPosition else {
            return nil
        }
        
        if (self.flasherPeriod <= 0) {
            return nil
        }
        
        // the flasher is "on" if it has been less than one-half of a flasher period
        // since the last time we turned on the flasher
        if (abs(self.flasherOnAt.timeIntervalSinceNow) < (self.flasherPeriod / 2)) {
            return flasherPosition
        // the flasher is "off" it has been between one-half and one flasher period
        // since the last time we turned on the flasher
        } else if (abs(self.flasherOnAt.timeIntervalSinceNow) < self.flasherPeriod) {
            return Point(xPos: flasherPosition.xPos, yPos: flasherPosition.yPos, color: Color(red: 0.0, green: 0.0, blue: 0.0))
        // more than one flasher period since the last time we turned "on" the flasher? turn it on again, remember time.
        } else {
            self.flasherOnAt = NSDate()
            return flasherPosition
        }
    }
}
