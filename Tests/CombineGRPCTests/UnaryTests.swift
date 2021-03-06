// Copyright 2019, Vy-Shane Xie
// Licensed under the Apache License, Version 2.0

import XCTest
import Combine
import GRPC
import NIO
@testable import CombineGRPC

@available(OSX 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class UnaryTests: XCTestCase {
  
  static var serverEventLoopGroup: EventLoopGroup?
  static var client: UnaryScenariosClient?
  static var retainedCancellables: Set<AnyCancellable> = []
  
  override class func setUp() {
    super.setUp()
    serverEventLoopGroup = try! makeTestServer(services: [UnaryTestsService()])
    client = makeTestClient { channel, callOptions in
      UnaryScenariosClient(channel: channel, defaultCallOptions: callOptions)
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
    let client = UnaryTests.client!
    let grpc = GRPCExecutor()
    
    grpc.call(client.ok)(EchoRequest.with { $0.message = "hello" })
      .sink(
        receiveCompletion: { switch $0 {
          case .failure(let status):
            XCTFail("Unexpected status: " + status.localizedDescription)
          case .finished:
            promise.fulfill()
        }},
        receiveValue: { response in
          XCTAssert(response.message == "hello")
        }
      )
      .store(in: &UnaryTests.retainedCancellables)
    
    wait(for: [promise], timeout: 0.2)
  }

  func testFailedPrecondition() {
    let promise = expectation(description: "Call fails with failed precondition status")
    let failedPrecondition = UnaryTests.client!.failedPrecondition
    let grpc = GRPCExecutor()
    
    grpc.call(failedPrecondition)(EchoRequest.with { $0.message = "hello" })
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
      .store(in: &UnaryTests.retainedCancellables)
    
    wait(for: [promise], timeout: 0.2)
  }

  func testNoResponse() {
    let promise = expectation(description: "Call fails with deadline exceeded status")
    let client = UnaryTests.client!
    let options = CallOptions(timeout: try! .milliseconds(50))
    let grpc = GRPCExecutor(callOptions: Just(options).eraseToAnyPublisher())
    
    grpc.call(client.noResponse)(EchoRequest.with { $0.message = "hello" })
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
      .store(in: &UnaryTests.retainedCancellables)
    
    wait(for: [promise], timeout: 0.2)
  }
  
  static var allTests = [
    ("Unary OK", testOk),
    ("Unary failed precondition", testFailedPrecondition),
    ("Unary no response", testNoResponse),
  ]
}
