//
//  ConfigurationSheetManager.swift
//  StarryExcuseForAMacScreensaver
//
//  Created by Andrew Malota on 5/2/19.
//  Copyright © 2019 Andrew Malota. All rights reserved.
//

import Foundation
import Cocoa
import os

class StarryConfigSheetController : NSWindowController {
    let defaultsManager = StarryDefaultsManager()
    weak var view: StarryExcuseForAView?
    private var log: OSLog?
    
    // stars
    @IBOutlet weak var starsPerUpdate: NSTextField!
    
    @IBOutlet weak var buildingHeightSlider: NSSlider!
    @IBOutlet weak var buildingHeightPreview: NSTextField!
    
    @IBOutlet weak var secsBetweenClears: NSTextField!
    
    @IBOutlet weak var moonTraversalMinutes: NSTextField!
    
    @IBAction func buildingHeightChanged(_ sender: Any) {
        buildingHeightPreview.stringValue = String.init(format: "%.3f", buildingHeightSlider.doubleValue)
    }
    
    public func setView(view: StarryExcuseForAView) {
        self.view = view
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        starsPerUpdate.integerValue = defaultsManager.starsPerUpdate
        buildingHeightSlider.doubleValue = defaultsManager.buildingHeight
        buildingHeightPreview.stringValue = String.init(format: "%.3f", defaultsManager.buildingHeight)
        secsBetweenClears.doubleValue = defaultsManager.secsBetweenClears
        moonTraversalMinutes.integerValue = defaultsManager.moonTraversalMinutes
        
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
    }
    
    @IBAction func saveClose(_ sender: Any) {
        os_log("hit saveClose", log: self.log!, type: .fault)
        
        defaultsManager.starsPerUpdate = starsPerUpdate.integerValue
        defaultsManager.buildingHeight = buildingHeightSlider.doubleValue
        defaultsManager.secsBetweenClears = secsBetweenClears.doubleValue
        defaultsManager.moonTraversalMinutes = moonTraversalMinutes.integerValue
        
        view?.settingsChanged()
        
        window!.sheetParent?.endSheet(self.window!, returnCode: NSApplication.ModalResponse.OK)
        self.window!.close()
        
        os_log("exiting saveClose", log: self.log!, type: .fault)
    }
    
}
