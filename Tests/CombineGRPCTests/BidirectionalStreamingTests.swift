// Copyright 2019, Vy-Shane Xie
// Licensed under the Apache License, Version 2.0

import XCTest
import Combine
import GRPC
import NIO
@testable import CombineGRPC

@available(OSX 10.15, iOS 13, tvOS 13, watchOS 6, *)
class BidirectionalStreamingTests: XCTestCase {
  
  static var serverEventLoopGroup: EventLoopGroup?
  static var client: BidirectionalStreamingScenariosClient?
  static var retainedCancellables: Set<AnyCancellable> = []
  
  override class func setUp() {
    super.setUp()
    serverEventLoopGroup = try! makeTestServer(services: [BidirectionalStreamingTestsService()])
    client = makeTestClient { channel, callOptions in
      BidirectionalStreamingScenariosClient(channel: channel, defaultCallOptions: callOptions)
    }
  }
  
  override class func tearDown() {
    try! client?.channel.close().wait()
    try! serverEventLoopGroup?.syncShutdownGracefully()
    retainedCancellables.removeAll()
    super.tearDown()
  }
  
  func testOk() {
    let promise = expectation(description: "Call completes successfully")
    let client = BidirectionalStreamingTests.client!
    let requests = repeatElement(EchoRequest.with { $0.message = "hello"}, count: 3)
    let requestStream = Publishers.Sequence<Repeated<EchoRequest>, Error>(sequence: requests).eraseToAnyPublisher()
    let grpc = GRPCExecutor()
    
    grpc.call(client.ok)(requestStream)
      .filter { $0.message == "hello" }
      .count()
      .sink(
        receiveCompletion: { switch $0 {
          case .failure(let status):
            XCTFail("Unexpected status: " + status.localizedDescription)
          case .finished:
            promise.fulfill()
        }},
        receiveValue: { count in
          XCTAssert(count == 3)
        }
      )
      .store(in: &BidirectionalStreamingTests.retainedCancellables)
    
    wait(for: [promise], timeout: 0.2)
  }
  
  func testFailedPrecondition() {
    let promise = expectation(description: "Call fails with failed precondition status")
    let failedPrecondition = BidirectionalStreamingTests.client!.failedPrecondition
    let requests = repeatElement(EchoRequest.with { $0.message = "hello"}, count: 3)
    let requestStream = Publishers.Sequence<Repeated<EchoRequest>, Error>(sequence: requests).eraseToAnyPublisher()
    let grpc = GRPCExecutor()
    
    grpc.call(failedPrecondition)(requestStream)
      .sink(
        receiveCompletion: { switch $0 {
          case .failure(let status):
            if status.code == .failedPrecondition {
              promise.fulfill()
            } else {
              XCTFail("Unexpected status: " + status.localizedDescription)
            }
          case .finished:
            XCTFail("Call should not succeed")
        }},
        receiveValue: { empty in
          XCTFail("Call should not return a response")
        }
      )
      .store(in: &BidirectionalStreamingTests.retainedCancellables)
    
    wait(for: [promise], timeout: 0.2)
  }
  
  func testNoResponse() {
    let promise = expectation(description: "Call fails with deadline exceeded status")
    let client = BidirectionalStreamingTests.client!
    let options = CallOptions(timeout: try! .milliseconds(50))
    let requests = repeatElement(EchoRequest.with { $0.message = "hello"}, count: 3)
    let requestStream = Publishers.Sequence<Repeated<EchoRequest>, Error>(sequence: requests).eraseToAnyPublisher()
    let grpc = GRPCExecutor(callOptions: Just(options).eraseToAnyPublisher())
    
    grpc.call(client.noResponse)(requestStream)
      .sink(
        receiveCompletion: { switch $0 {
          case .failure(let status):
            if status.code == .deadlineExceeded {
              promise.fulfill()
            } else {
              XCTFail("Unexpected status: " + status.localizedDescription)
            }
          case .finished:
            XCTFail("Call should not succeed")
        }},
        receiveValue: { empty in
          XCTFail("Call should not return a response")
        }
      )
      .store(in: &BidirectionalStreamingTests.retainedCancellables)
    
    wait(for: [promise], timeout: 0.2)
  }
  
  func testClientStreamError() {
    let promise = expectation(description: "Call fails with cancelled status")
    let client = BidirectionalStreamingTests.client!
    let grpc = GRPCExecutor()
    
    struct ClientStreamError: Error {}
    let requests = Fail<EchoRequest, Error>(error: ClientStreamError()).eraseToAnyPublisher()
    
    grpc.call(client.ok)(requests)
      .sink(
        receiveCompletion: { completion in
          switch completion {
          case .failure(let status):
            if status.code == .cancelled {
              promise.fulfill()
            } else {
              XCTFail("Unexpected status: " + status.localizedDescription)
            }
          case .finished:
            XCTFail("Call should not succeed")
          }
        },
        receiveValue: { response in
          XCTFail("Call should not return a response")
        }
      )
      .store(in: &ClientStreamingTests.retainedCancellables)
    
    wait(for: [promise], timeout: 0.2)
  }
  
  static var allTests = [
    ("Bidirectional streaming OK", testOk),
    ("Bidirectional streaming failed precondition", testFailedPrecondition),
    ("Bidirectional streaming no response", testNoResponse),
    ("Bidirectional streaming with client stream error, stream cancelled", testClientStreamError),
  ]
}
