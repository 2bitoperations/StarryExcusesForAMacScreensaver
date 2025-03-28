import Cocoa

class StarryExcuseForAView: ScreenSaverView {
    private var log: OSLog?
    private var skyline: Skyline?
    private var skylineRenderer: SkylineCoreRenderer?
    private var currentContext: CGContext?
    private var image: CGImage?
    private var imageView: NSImageView?
    private var size: CGSize?
    private var traceEnabled: Bool
    private lazy var configSheetController: StarryConfigSheetController = StarryConfigSheetControll
    private var defaultsManager = StarryDefaultsManager()
    
    public override var hasConfigureSheet: Bool {
        get { return true }
    }
    
    public override var configureSheet: NSWindow? {
        get {
            configSheetController.setView(view: self)
            return configSheetController.window
        }
    }
    
    override init?(frame: NSRect, isPreview: Bool) {
        self.traceEnabled = false
        super.init(frame: frame, isPreview: isPreview)
        os_log("start skyline init")
        
        if self.log == nil {
            self.log = OSLog(subsystem: "com.2bitoperations.screensavers.starry", category: "Skylin
        }
        
        self.animationTimeInterval = TimeInterval(0.1)
    }
    
    required init?(coder decoder: NSCoder) {
        self.traceEnabled = false
        super.init(coder: decoder)
    }
    
    func screenshot() -> CGImage {
        let windows = CGWindowListCopyWindowInfo(CGWindowListOption.optionOnScreenOnly, kCGNullWind
        let loginwindow = windows.first(where: { (element) -> Bool in
            return element[kCGWindowOwnerName as String] as! String == "loginwindow"
        })
        let loginwindowID = (loginwindow != nil) ? CGWindowID(loginwindow![kCGWindowNumber as Strin
        return CGWindowListCreateImage(CGDisplayBounds(self.window?.screen?.deviceDescription[NSDev
                                       CGWindowListOption.optionOnScreenBelowWindow, loginwindowID,
    }
    
    override func startAnimation() {
        let image = screenshot()
        let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height), bits
        self.size = CGSize.init(width: context.width, height: context.height)
        self.currentContext = context
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(frame.width), height: Int(frame.heigh
    }
    
    override func stopAnimation() {
        super.stopAnimation()
    }
    
    func settingsChanged() {
        self.skyline = nil
    }
    
    override open func animateOneFrame() {
        guard let context = self.currentContext else {
            os_log("context not present, can't animate one", log: self.log!, type: .fault)
            return
        }
        guard let skyline = self.skyline else {
            os_log("skyline not present, can't animate one", log: self.log!, type: .fault)
            return
        }
        guard let size = self.size else {
    }
    
    private func clearScreen(contextOpt: CGContext?) {
        guard let context = contextOpt else {
            os_log("context not present, can't clear", log: self.log!, type: .fault)
            return
        }
        let rect = CGRect(origin: CGPoint(x: 0, y: 0), size: self.size!)
        context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        context.fill(rect)
        
        os_log("screen cleared", log: self.log!, type: .info)
    }
    
    fileprivate func initSkyline(xMax: Int, yMax: Int) {
        do {
            self.skyline = try Skyline(screenXMax: xMax,
                                       screenYMax: yMax,
                                       buildingHeightPercentMax: self.defaultsManager.buildingHeigh
                                       starsPerUpdate: self.defaultsManager.starsPerUpdate,
                                       log: self.log!,
                                       clearAfterDuration: TimeInterval(self.defaultsManager.secsBe
                                       traceEnabled: traceEnabled)
            self.skylineRenderer = SkylineCoreRenderer(skyline: self.skyline!, log: self.log!, trac
        } catch {
            let msg = "\(error)"
    }
}
