# CombineGRPC

## Status

This library is not ready for production use. CombineGRPC uses the NIO implementation of Swift gRPC, currently at version 1.0.0-alpha.5, and integrates with Apple's new Combine framework, which is still in beta.

## gRPC and Combine, Better Together

CombineGRPC is a library that provides [Combine framework](https://developer.apple.com/documentation/combine) integration for [Swift gRPC](https://github.com/grpc/grpc-swift). It provides two flavours of functionality, `call` and `handle`. Use `call` to make gRPC calls on the client side, and `handle` to handle incoming RPC calls on the server side. CombineGRPC provides versions of `call` and `handle` for all RPC styles. Here are the input and output types for each.

RPC Style | Input and Output Types
--- | ---
| Unary | `Request -> AnyPublisher<Response, GRPCStatus>` |
| Server streaming | `Request -> AnyPublisher<Response, GRPCStatus>` |
| Client streaming | `AnyPublisher<Request, Error> -> AnyPublisher<Response, GRPCStatus>` |
| Bidirectional streaming | `AnyPublisher<Request, Error> -> AnyPublisher<Response, GRPCStatus>` |

When you make a unary call, you provide a request message, and get back a response publisher. The response publisher will either publish a single response, or fail with a `GRPCStatus` error. Similarly, if you are handling a unary RPC call, you provide a handler that takes a request parameter and returns an `AnyPublisher<Response, GRPCStatus>`.

You can follow the same intuition to understand the types for the other RPC styles. The only difference is that publishers for the streaming RPCs may publish zero or more messages instead of the single response message that is expected from the unary response publisher.

## Quick Tour

Let's see a quick example. Consider the following protobuf definition for a simple echo service. The service defines one bidirectional RPC. You send it a stream of messages and it echoes the messages back to you.

```protobuf
syntax = "proto3";

service EchoService {
  rpc SayItBack (stream EchoRequest) returns (stream EchoResponse);
}

message EchoRequest {
  string message = 1;
}

message EchoResponse {
  string message = 1;
}
```

### Server Side

To implement the server, you provide a handler function that takes an input stream `AnyPublisher<EchoRequest, Error>` and returns an output stream `AnyPublisher<EchoResponse, GRPCStatus>`.

```swift
import Foundation
import Combine
import CombineGRPC
import GRPC
import NIO

class EchoServiceProvider: EchoProvider {
  
  // Simple bidirectional RPC that echoes back each request message
  func sayItBack(context: StreamingResponseCallContext<EchoResponse>) -> EventLoopFuture<(StreamEvent<EchoRequest>) -> Void> {
    handle(context) { requests in
      requests
        .map { req in
          EchoResponse.with { $0.message = req.message }
        }
        .setFailureType(to: GRPCStatus.self)
        .eraseToAnyPublisher()
    }
  }
}
```

Start the server. This is the same process as with Swift gRPC.

```swift
let configuration = Server.Configuration(
  target: ConnectionTarget.hostAndPort("localhost", 8080),
  eventLoopGroup: PlatformSupport.makeEventLoopGroup(loopCount: 1),
  serviceProviders: [EchoServiceProvider()]
)
_ = try Server.start(configuration: configuration).wait()
```

### Client Side

Now let's setup our client. Again, it's the same process that you would go through when using Swift gRPC.

```swift
let configuration = ClientConnection.Configuration(
  target: ConnectionTarget.hostAndPort("localhost", 8080),
  eventLoopGroup: PlatformSupport.makeEventLoopGroup(loopCount: 1)
)
let echoClient = EchoServiceClient(connection: ClientConnection(configuration: configuration))
```

To call the service, create a `GRPCExecutor` and use its `call` method. You provide it with a stream of requests `AnyPublisher<EchoRequest, Error>` and you get back a stream `AnyPublisher<EchoResponse, GRPCStatus>` of responses from the server.

```swift
let requests = repeatElement(EchoRequest.with { $0.message = "hello"}, count: 10)
let requestStream: AnyPublisher<EchoRequest, Error> =
  Publishers.Sequence(sequence: requests).eraseToAnyPublisher()
let grpc = GRPCExecutor()

grpc.call(echoClient.sayItBack)(requestStream)
  .filter { $0.message == "hello" }
  .count()
  .sink(receiveValue: { count in
    assert(count == 10)
  })
```

That's it! You have set up bidirectional streaming between a server and client. The method `sayItBack` of `EchoServiceClient` is generated by Swift gRPC. Notice that call is curried. You can preselect RPC calls using partial application:

```swift
let sayItBack = grpc.call(echoClient.sayItBack)

sayItBack(requestStream).map { response in
  // ...
}
```

### Configuring RPC Calls

The `GRPCExecutor` allows you to configure `CallOptions` for your RPC calls. You can provide the `GRPCExecutor`'s initializer with a stream `AnyPublisher<CallOptions, Never>`, and the latest `CallOptions` value will be used when making calls. 

```swift
let timeoutOptions = CallOptions(timeout: try! .seconds(5))
let grpc = GRPCExecutor(callOptions: Just(timeoutOptions).eraseToAnyPublisher())
```

### Retry Policy

You can also configure `GRPCExecutor` to automatically retry failed calls by specifying a `RetryPolicy`. In the following example, we retry calls that fail with status  `.unauthenticated`. We use `CallOptions` to add a Bearer token to the authorization header, and then retry the call.

```swift
// Default CallOptions with no authentication
let callOptions = CurrentValueSubject<CallOptions, Never>(CallOptions())

let grpc = GRPCExecutor(
  callOptions: callOptions.eraseToAnyPublisher(),
  retry: .failedCall(
    upTo: 1,
    when: { status in
      status.code == .unauthenticated
    },
    delayUntilNext: { retryCount in  // Useful for implementing exponential backoff
      // Retry the call with authentication
      callOptions.send(CallOptions(customMetadata: HTTPHeaders([("authorization", "Bearer xxx")])))
      return Just(()).eraseToAnyPublisher()
    },
    onGiveUp: {
      print("Authenticated call failed.")
    }
  )
)

grpc.call(client.authenticatedRpc)(request)
  .map { response in
    // ...
  }
```

You can imagine doing something along those lines to seamlessly retry calls when an ID token expires. The back-end service replies with status `.unauthenticated`, you obtain a new ID token using your refresh token, and the call is retried.

### More Examples

Check out the [CombineGRPC tests](Tests/CombineGRPCTests) for examples of all the different RPC calls and handlers implementations. You can find the matching protobuf [here](Tests/Protobuf/test_scenarios.proto).

## Logistics

### Generating Swift Code from Protobuf

To generate Swift code from your .proto files, you'll need to first install the [protoc](https://github.com/protocolbuffers/protobuf) Protocol Buffer compiler and the [swift-protobuf](https://github.com/apple/swift-protobuf) plugin.

```text
brew install protobuf
brew install swift-protobuf
```

Next, download the latest version of grpc-swift with NIO support. Currently that means [Swift gRPC 1.0.0-alpha.5](https://github.com/grpc/grpc-swift/releases/tag/1.0.0-alpha.5). Unarchive the downloaded file and build the Swift gRPC plugin by running make in the root directory of the project.

```text
make plugin
```

Put the built binary somewhere in your $PATH. Now you are ready to generate Swift code from protobuf interface definition files.

Let's generate the message types, gRPC server and gRPC client for Swift.

```text
protoc example_service.proto --swift_out=Generated/
protoc example_service.proto --swiftgrpc_out=Generated/
```

You'll see that protoc has created two source files for us.

```text
ls Generated/
example_service.grpc.swift
example_service.pb.swift
```

### Adding CombineGRPC to Your Project

You can add CombineGRPC using Swift Package Manager by listing it as a dependency to your Package.swift configuration file.

```swift
dependencies: [
  .package(url: "https://github.com/vyshane/grpc-swift-combine.git", from: "0.6.0"),
],
```

## Compatibility

Since this library integrates with Combine, it only works on platforms that support Combine. This currently means the following minimum versions: macOS 10.15 Catalina, iOS 13, watchOS 6 and tvOS 13.

## Project Status

RPC Client Calls

- [x] Unary
- [x] Client streaming
- [x] Server streaming
- [x] Bidirectional streaming
- [x] Retry policy for automatic client call retries

Server Side Handlers

- [x] Unary
- [x] Client streaming
- [x] Server streaming
- [x] Bidirectional streaming

End-to-end Tests

- [x] Unary
- [x] Client streaming
- [x] Server streaming
- [x] Bidirectional streaming

Documentation

- [x] README.md
- [x] Inline documentation using markup in comments
