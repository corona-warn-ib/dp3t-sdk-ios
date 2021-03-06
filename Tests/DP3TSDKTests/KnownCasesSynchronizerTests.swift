/*
 * Copyright (c) 2020 Ubique Innovation AG <https://www.ubique.ch>
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * SPDX-License-Identifier: MPL-2.0
 */

import Foundation

@testable import DP3TSDK
import Foundation
import XCTest

private class MockMatcher: Matcher {
    var timingManager: ExposureDetectionTimingManager?

    var delegate: MatcherDelegate?

    var error: Error?

    var timesCalledNewKnownCaseDate: Int = 0

    var timesToAddDetection: Int = 0

    func receivedNewKnownCaseData(_: Data, keyDate _: Date) throws {
        timesCalledNewKnownCaseDate += 1
        timesToAddDetection += 1
    }

    func finalizeMatchingSession(now: Date) throws {
        if let error = error {
            throw error
        } else {
            for _ in 0..<timesToAddDetection {
                timingManager?.addDetection(timestamp: now)
            }
        }
        timesToAddDetection = 0
    }
}

private class MockService: ExposeeServiceClientProtocol {
    var requests: [Date] = []
    let session = MockSession(data: "Data".data(using: .utf8), urlResponse: nil, error: nil)
    let queue = DispatchQueue(label: "synchronous")
    var error: DP3TNetworkingError?
    var publishedUntil: Date = .init()
    var data: Data? = "Data".data(using: .utf8)

    func getExposee(batchTimestamp: Date, completion: @escaping (Result<ExposeeSuccess, DP3TNetworkingError>) -> Void) -> URLSessionDataTask {
        return session.dataTask(with: .init(url: URL(string: "http://www.google.com")!)) { _, _, _ in
            if let error = self.error {
                completion(.failure(error))
            } else {
                self.queue.sync {
                    self.requests.append(batchTimestamp)
                }
                completion(.success(.init(data: self.data, publishedUntil: self.publishedUntil)))
            }
        }
    }

    func addExposeeList(_: ExposeeListModel, authentication _: ExposeeAuthMethod, completion _: @escaping (Result<OutstandingPublish, DP3TNetworkingError>) -> Void) {}

    func addDelayedExposeeList(_: DelayedKeyModel, token _: String?, completion _: @escaping (Result<Void, DP3TNetworkingError>) -> Void) {}
}

final class KnownCasesSynchronizerTests: XCTestCase {
    func testInitialToday() {
        let matcher = MockMatcher()
        let service = MockService()
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))
        let expecation = expectation(description: "syncExpectation")
        sync.sync { _ in
            expecation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(service.requests.count, 10)
        XCTAssert(service.requests.contains(DayDate().dayMin))
        XCTAssert(!defaults.lastSyncTimestamps.isEmpty)
    }

    func testInitialLoadingFirstBatch() {
        let matcher = MockMatcher()
        let service = MockService()
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))
        let expecation = expectation(description: "syncExpectation")
        sync.sync(now: .init(timeIntervalSinceNow: .hour)) { _ in
            expecation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(service.requests.count, 10)
        XCTAssertEqual(defaults.lastSyncTimestamps.count, 10)
    }

    func testOnlyCallingMatcherTwiceADay() {
        let matcher = MockMatcher()
        let service = MockService()
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))

        let today = DayDate().dayMin
        for i in 0 ..< 24 * 4 {
            let time = today.addingTimeInterval(Double(i) * TimeInterval.hour / 4)
            let expecation = expectation(description: "syncExpectation")
            sync.sync(now: time) { _ in
                expecation.fulfill()
            }
            waitForExpectations(timeout: 1)
        }
        XCTAssertEqual(matcher.timesCalledNewKnownCaseDate, 20)
    }

    func testOnlyCallingMatcherOverMultipleDays() {
        let matcher = MockMatcher()
        let service = MockService()
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))

        let today = DayDate().dayMin
        let days = 3
        for i in 0 ..< 24 * days {
            let time = today.addingTimeInterval(Double(i) * TimeInterval.hour)
            let expecation = expectation(description: "syncExpectation")
            sync.sync(now: time) { _ in
                expecation.fulfill()
            }
            waitForExpectations(timeout: 1)
        }
        XCTAssertEqual(matcher.timesCalledNewKnownCaseDate, days * 20)
    }

    func testStoringLastSyncNoData() {
        let matcher = MockMatcher()
        let service = MockService()
        service.data = nil
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))
        let expecation = expectation(description: "syncExpectation")
        sync.sync(now: .init(timeIntervalSinceNow: .hour)) { _ in
            expecation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(service.requests.count, 10)
        XCTAssertEqual(defaults.lastSyncTimestamps.count, 10)
    }

    func testInitialLoadingManyBatches() {
        let matcher = MockMatcher()
        let service = MockService()
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))
        let expecation = expectation(description: "syncExpectation")
        sync.sync(now: .init(timeIntervalSinceNow: .day * 15)) { _ in
            expecation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(service.requests.count, defaults.parameters.networking.daysToCheck)
        XCTAssertEqual(defaults.lastSyncTimestamps.count, defaults.parameters.networking.daysToCheck)
    }

    func testDontStoreLastSyncNetworkingError() {
        let matcher = MockMatcher()
        let service = MockService()
        service.error = .couldNotEncodeBody
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))
        let expecation = expectation(description: "syncExpectation")
        sync.sync(now: .init(timeIntervalSinceNow: .hour)) { _ in
            expecation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssert(defaults.lastSyncTimestamps.isEmpty)
    }

    func testDontStoreLastSyncMatchingError() {
        let matcher = MockMatcher()
        let service = MockService()
        matcher.error = DP3TTracingError.bluetoothTurnedOff
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))
        let expecation = expectation(description: "syncExpectation")
        sync.sync(now: .init(timeIntervalSinceNow: .hour)) { _ in
            expecation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssert(defaults.lastSyncTimestamps.isEmpty)
    }

    func testRepeatingRequestsAfterDay() {
        let matcher = MockMatcher()
        let service = MockService()
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))
        let expecation = expectation(description: "syncExpectation")
        sync.sync(now: .init(timeIntervalSinceNow: .hour)) { _ in
            expecation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(service.requests.count, 10)
        XCTAssertEqual(defaults.lastSyncTimestamps.count, 10)

        service.requests = []

        let secondExpectation = expectation(description: "secondSyncExpectation")
        sync.sync(now: .init(timeIntervalSinceNow: .hour + .day)) { _ in
            secondExpectation.fulfill()
        }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(service.requests.count, 10)
        XCTAssertEqual(defaults.lastSyncTimestamps.count, 10)
    }

    func testCallingSyncMulithreaded() {
        let matcher = MockMatcher()
        let service = MockService()
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))

        let expecation = expectation(description: "syncExpectation")
        let iterations = 50
        expecation.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            sync.sync(now: .init(timeIntervalSinceNow: .hour)) { _ in
                expecation.fulfill()
            }
        }

        waitForExpectations(timeout: 1)

        XCTAssertEqual(service.requests.count, 10)
        XCTAssertEqual(defaults.lastSyncTimestamps.count, 10)
    }

    func testCallingSyncMulithreadedWithCancel() {
        let matcher = MockMatcher()
        let service = MockService()
        let defaults = MockDefaults()
        let sync = KnownCasesSynchronizer(matcher: matcher,
                                          service: service,
                                          defaults: defaults,
                                          descriptor: .init(appId: "ch.dpppt", bucketBaseUrl: URL(string: "http://www.google.de")!, reportBaseUrl: URL(string: "http://www.google.de")!))

        sync.sync(now: .init(timeIntervalSinceNow: .hour)) { result in
            switch result {
            case let .failure(error):
                switch error {
                case .cancelled:
                    break
                default:
                    XCTFail()
                }
            default:
                XCTFail()
            }
        }
        sync.cancelSync()

        let exp = expectation(description: "Test after 2 seconds")
        _ = XCTWaiter.wait(for: [exp], timeout: 2.0)

        XCTAssertNotEqual(service.requests.count, 10)
        XCTAssertNotEqual(defaults.lastSyncTimestamps.count, 10)
    }
}
