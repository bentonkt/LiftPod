import XCTest
@testable import LiftPod

final class ProviderAbstractionTests: XCTestCase {
    func testCallbackIndexerIsSequentialAndResetsForNewRun() {
        var indexer = HeadphoneMotionProvider.CallbackIndexer()
        XCTAssertEqual(indexer.next(), 1)
        XCTAssertEqual(indexer.next(), 2)
        indexer.reset()
        XCTAssertEqual(indexer.next(), 1)
    }

    func testStartAndStopAreIdempotentAndDoNotDuplicateStreams() async {
        let provider = MockMotionProvider()
        let stream = provider.makeEventStream()
        provider.start()
        provider.start()
        XCTAssertEqual(provider.startCallCount, 1)
        XCTAssertEqual(provider.activeStreamCount, 1)

        provider.stop()
        provider.stop()
        XCTAssertEqual(provider.stopCallCount, 1)
        _ = stream
    }

    func testSampleDeliveryThroughStream() async {
        let provider = MockMotionProvider()
        let stream = provider.makeEventStream()
        let expected = makeSample(index: 7)
        provider.emit(.sample(expected))

        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event, .sample(expected))
    }

    func testSyntheticSamplesRetainSequentialIndices() async {
        let provider = MockMotionProvider()
        let stream = provider.makeEventStream()
        provider.emit(.sample(makeSample(index: 1)))
        provider.emit(.sample(makeSample(index: 2)))

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        guard case let .sample(firstSample) = first, case let .sample(secondSample) = second else {
            return XCTFail("Expected two samples")
        }
        XCTAssertEqual(firstSample.index, 1)
        XCTAssertEqual(secondSample.index, 2)
    }
}
