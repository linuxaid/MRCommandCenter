import Foundation
import Testing
@testable import MR_Command_Center

struct CachePolicyTests {
    let updated = Date(timeIntervalSince1970: 1_790_000_000.123)

    @Test func fetchesDetailsWhenNeverFetched() {
        #expect(CachePolicy.needsDetailRefresh(detailsFetchedForUpdatedAt: nil, remoteUpdatedAt: updated))
    }

    @Test func skipsDetailsWhenUpdatedAtUnchanged() {
        #expect(!CachePolicy.needsDetailRefresh(detailsFetchedForUpdatedAt: updated, remoteUpdatedAt: updated))
    }

    @Test func refetchesDetailsWhenUpdatedAtChanged() {
        #expect(CachePolicy.needsDetailRefresh(detailsFetchedForUpdatedAt: updated, remoteUpdatedAt: updated.addingTimeInterval(1)))
    }

    @Test func forceAlwaysRefetches() {
        #expect(CachePolicy.needsDetailRefresh(detailsFetchedForUpdatedAt: updated, remoteUpdatedAt: updated, force: true))
    }

    @Test(arguments: PipelineStatus.allCases)
    func repollsOnlyActivePipelines(status: PipelineStatus) {
        let expected = [.created, .waitingForResource, .preparing, .pending, .running, .scheduled].contains(status)
        #expect(CachePolicy.needsPipelineRefresh(cachedStatus: status, pipelineID: 1) == expected)
    }

    @Test func noPipelineMeansNoRepoll() {
        #expect(!CachePolicy.needsPipelineRefresh(cachedStatus: .running, pipelineID: nil))
        #expect(!CachePolicy.needsPipelineRefresh(cachedStatus: nil, pipelineID: 5))
    }
}
