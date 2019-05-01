//
//  StarryExcusesForTests.swift
//  StarryExcusesForTests
//
//  Created by Andrew Malota on 4/30/19.
//  Copyright © 2019 Andrew Malota. All rights reserved.
//

import XCTest

class StarryExcusesForTests: XCTestCase {

    override func setUp() {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() {
        let skyline = Skyline(screenXMax: 800, screenYMax: 600)
        XCTAssertNotNil(skyline)
        let star = skyline.getSingleStar()
        XCTAssertNotNil(star)
    }

    func testPerformanceExample() {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}
