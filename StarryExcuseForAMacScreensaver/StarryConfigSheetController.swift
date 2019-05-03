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
    var view: StarryExcuseForAView?
    private var log: OSLog?
    
    // stars
    @IBOutlet weak var starsPerUpdate: NSTextField!
    
    public func setView(view: StarryExcuseForAView) {
        self.view = view
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        
        starsPerUpdate.integerValue = defaultsManager.starsPerUpdate
        self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skyline")
    }
    
    @IBAction func saveClose(_ sender: Any) {
        os_log("hit saveClose", log: self.log!, type: .fault)
        
        defaultsManager.starsPerUpdate = starsPerUpdate.integerValue
        
        view?.settingsChanged()
        
        window!.sheetParent?.endSheet(self.window!, returnCode: NSApplication.ModalResponse.OK)
        self.window!.close()
        
        os_log("exiting saveClose", log: self.log!, type: .fault)
    }
    
}
