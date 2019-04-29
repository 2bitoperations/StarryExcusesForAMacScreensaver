//
//  StarryExcusesView.swift
//  OnelinerKit
//
//  Original Code:
//  Created by Marcus Kida on 17.12.17.
//  Copyright © 2017 Marcus Kida. All rights reserved.
//
//  Modifications:
//  Modified by Andrew Malota (2bitoperations) on 2018-12
//  Copyright © 2018 Andrew Malota. All rights reserved.
//
//  Original code and modifications released under the MIT license.
//

import ScreenSaver
import Foundation

@available(OSX 10.10, *)
open class StarryExcusesView: ScreenSaverView {
    private let fetchQueue = DispatchQueue(label: .fetchQueue)
    private let mainQueue = DispatchQueue.main
    
    private var fetchingDue = true
    private var lastFetchDate: Date?
    
    public var backgroundColor = NSColor.black
    public var textColor = NSColor.white
    
    private var skyDraw: SkylineDraw?
    
    convenience init() {
        self.init(frame: .zero, isPreview: false)
        initialize()
    }
    
    override init!(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        initialize()
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        initialize()
    }
    
    override open var configureSheet: NSWindow? {
        return nil
    }
    
    override open var hasConfigureSheet: Bool {
        return false
    }
    
    override open func animateOneFrame() {
        return
    }
    
    override open func draw(_ rect: NSRect) {
        super.draw(rect)
        
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        
        //let skyline = Skyline(screenXMax: rect, screenYMax: <#T##Int#>)
        //self.skyDraw = SkylineDraw
    }
    
    private func initialize() {
        animationTimeInterval = 0.05
        scheduleNext()
    }
    
    private func scheduleNext() {
        mainQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let 🕑 = self?.lastFetchDate else {
                return
            }
            guard Date().isFetchDue(since: 🕑) else {
                self?.scheduleNext()
                return
            }
        }
    }
}
