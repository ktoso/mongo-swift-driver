import Foundation
@testable import MongoSwift
import Nimble
import XCTest

extension String {
    /// Removes the first occurrence of the specified substring from the string. If the substring is not present, has
    /// no effect.
    public mutating func removeSubstring(_ s: String) {
        guard s.count <= self.count else {
            return
        }
        for i in 0...(self.count - s.count) {
            let startIdx = self.index(self.startIndex, offsetBy: i)
            let endIdx = self.index(startIdx, offsetBy: s.count)
            if self[startIdx..<endIdx] == s {
                self.removeSubrange(startIdx..<endIdx)
                return
            }
        }
    }
}

open class MongoSwiftTestCase: XCTestCase {
    /// Gets the name of the database the test case is running against.
    public class var testDatabase: String {
        "test"
    }

    /// Gets the connection string to use from the environment variable, $MONGODB_URI. If the variable does not exist,
    /// will return a default of "mongodb://127.0.0.1/". If singleMongos is true and this is a sharded topology, will
    /// edit $MONGODB_URI as needed so that it only contains a single host.
    public static func getConnectionString(singleMongos: Bool = true) -> String {
        let uri = Self.uri

        // we only need to manipulate the URI if singleMongos is requested and the topology is sharded.
        guard singleMongos && MongoSwiftTestCase.topologyType == .sharded else {
            return uri
        }

        guard let hosts = try? ConnectionString(uri).hosts else {
            return uri
        }

        var output = uri
        // remove all but the first host so we connect to a single mongos.
        for host in hosts[1...] {
            output.removeSubstring(",\(host.description)")
        }
        return output
    }

    /// Get a connection string for the specified host only.
    public static func getConnectionString(forHost serverAddress: ServerAddress) -> String {
        Self.getConnectionStringPerHost().first { $0.contains(String(describing: serverAddress)) }!
    }

    /// Returns a different connection string per host specified in MONGODB_URI.
    public static func getConnectionStringPerHost() -> [String] {
        let uri = Self.uri

        let regex = try! NSRegularExpression(pattern: #"mongodb:\/\/(?:.*@)?([^\/]+)(?:\/|$)"#)
        let range = NSRange(uri.startIndex..<uri.endIndex, in: uri)
        let match = regex.firstMatch(in: uri, range: range)!

        let hostsRange = Range(match.range(at: 1), in: uri)!

        return try! ConnectionString(uri).hosts!.map { host in
            uri.replacingCharacters(in: hostsRange, with: host.description)
        }
    }

    // indicates whether we are running on a 32-bit platform
    public static let is32Bit = MemoryLayout<Int>.size == 4

    /// Generates a unique collection name of the format "<Test Suite>_<Test Name>_<suffix>". If no suffix is provided,
    /// the last underscore is omitted.
    public func getCollectionName(suffix: String? = nil) -> String {
        var name = self.name.replacingOccurrences(of: "[\\[\\]-]", with: "", options: [.regularExpression])
        if let suf = suffix {
            name += "_" + suf
        }
        return name.replacingOccurrences(of: "[ \\+\\$]", with: "_", options: [.regularExpression])
    }

    public func getNamespace(suffix: String? = nil) -> MongoNamespace {
        MongoNamespace(db: Self.testDatabase, collection: self.getCollectionName(suffix: suffix))
    }

    public static var topologyType: TopologyDescription.TopologyType {
        guard let topology = ProcessInfo.processInfo.environment["MONGODB_TOPOLOGY"] else {
            return .single
        }
        return TopologyDescription.TopologyType(from: topology)
    }

    public static var uri: String {
        guard let uri = ProcessInfo.processInfo.environment["MONGODB_URI"] else {
            return "mongodb://127.0.0.1/"
        }
        return uri
    }

    /// Indicates that we are running the tests with SSL enabled, determined by the environment variable $SSL.
    public static var ssl: Bool {
        ProcessInfo.processInfo.environment["SSL"] == "ssl"
    }

    /// Returns the path where the SSL key file is located, determined by the environment variable $SSL_KEY_FILE.
    public static var sslPEMKeyFilePath: String? {
        ProcessInfo.processInfo.environment["SSL_KEY_FILE"]
    }

    /// Returns the path where the SSL CA file is located, determined by the environment variable $SSL_CA_FILE..
    public static var sslCAFilePath: String? {
        ProcessInfo.processInfo.environment["SSL_CA_FILE"]
    }

    /// Indicates that we are running the tests with auth enabled, determined by the environment variable $AUTH.
    public static var auth: Bool {
        ProcessInfo.processInfo.environment["AUTH"] == "auth"
    }
}

/// Enumerates the different topology configurations that are used throughout the tests
public enum TestTopologyConfiguration: String, Decodable {
    case sharded
    case replicaSet = "replicaset"
    case single

    /// Determines the topologyType of a client based on the reply returned by running an isMaster command
    public init(isMasterReply: BSONDocument) throws {
        // Check for symptoms of different topologies
        if isMasterReply["msg"] != "isdbgrid" &&
            isMasterReply["setName"] == nil &&
            isMasterReply["isreplicaset"] != true {
            self = .single
        } else if isMasterReply["msg"] == "isdbgrid" {
            self = .sharded
        } else if isMasterReply["ismaster"] == true && isMasterReply["setName"] != nil {
            self = .replicaSet
        } else {
            fatalError("Invalid test topology configuration given by isMaster reply: \(isMasterReply)")
        }
    }
}

/// Enumerates different possible unmet requirements that can be returned by meetsRequirements
public enum UnmetRequirement {
    case minServerVersion(actual: ServerVersion, required: ServerVersion)
    case maxServerVersion(actual: ServerVersion, required: ServerVersion)
    case topology(actual: TestTopologyConfiguration, required: [TestTopologyConfiguration])
}

/// Struct representing conditions that a deployment must meet in order for a test file to be run.
public struct TestRequirement: Decodable {
    private let minServerVersion: ServerVersion?
    private let maxServerVersion: ServerVersion?
    private let topology: [TestTopologyConfiguration]?

    public init(
        minServerVersion: ServerVersion? = nil,
        maxServerVersion: ServerVersion? = nil,
        acceptableTopologies: [TestTopologyConfiguration]? = nil
    ) {
        self.minServerVersion = minServerVersion
        self.maxServerVersion = maxServerVersion
        self.topology = acceptableTopologies
    }

    /// Determines if the given deployment meets this requirement.
    public func getUnmetRequirement(
        givenCurrent version: ServerVersion,
        _ topology: TestTopologyConfiguration
    ) -> UnmetRequirement? {
        if let minVersion = self.minServerVersion {
            guard minVersion <= version else {
                return .minServerVersion(actual: version, required: minVersion)
            }
        }
        if let maxVersion = self.maxServerVersion {
            guard maxVersion >= version else {
                return .maxServerVersion(actual: version, required: maxVersion)
            }
        }
        if let topologies = self.topology {
            guard topologies.contains(topology) else {
                return .topology(actual: topology, required: topologies)
            }
        }
        return nil
    }
}

extension BSONDocument {
    public func sortedEquals(_ other: BSONDocument) -> Bool {
        let keys = self.keys.sorted()
        let otherKeys = other.keys.sorted()

        // first compare keys, because rearrangeDoc will discard any that don't exist in `expected`
        expect(keys).to(equal(otherKeys))

        let rearranged = rearrangeDoc(other, toLookLike: self)
        return self == rearranged
    }

    /**
     * Allows retrieving and strongly typing a value at the same time. This means you can avoid
     * having to cast and unwrap values from the `Document` when you know what type they will be.
     * For example:
     * ```
     *  let d: Document = ["x": 1]
     *  let x: Int = try d.get("x")
     *  ```
     *
     *  - Parameters:
     *      - key: The key under which the value you are looking up is stored
     *      - `T`: Any type conforming to the `BSONValue` protocol
     *  - Returns: The value stored under key, as type `T`
     *  - Throws:
     *    - `MongoError.InternalError` if the value cannot be cast to type `T` or is not in the `Document`, or an
     *      unexpected error occurs while decoding the `BSONValue`.
     *
     */
    public func get<T: BSONValue>(_ key: String) throws -> T {
        guard let value = try self.getValue(for: key)?.bsonValue as? T else {
            throw MongoError.InternalError(message: "Could not cast value for key \(key) to type \(T.self)")
        }
        return value
    }
}

/// Cleans and normalizes a given JSON string for comparison purposes
private func clean(json: String?) -> String {
    guard let str = json else {
        return ""
    }
    do {
        let doc = try BSONDocument(fromJSON: str.data(using: .utf8)!)
        return doc.toExtendedJSONString()
    } catch {
        print("Failed to clean string: \(str)")
        return String()
    }
}

// Adds a custom "cleanEqual" predicate that compares two JSON strings for equality after normalizing
// them with the "clean" function
public func cleanEqual(_ expectedValue: String?) -> Predicate<String> {
    Predicate.define("cleanEqual <\(stringify(expectedValue))>") { actualExpression, msg in
        let actualValue = try actualExpression.evaluate()
        let matches = clean(json: actualValue) == clean(json: expectedValue) && expectedValue != nil
        if expectedValue == nil || actualValue == nil {
            if expectedValue == nil && actualValue != nil {
                return PredicateResult(
                    status: .fail,
                    message: msg.appendedBeNilHint()
                )
            }
            return PredicateResult(status: .fail, message: msg)
        }
        return PredicateResult(status: PredicateStatus(bool: matches), message: msg)
    }
}

// Adds a custom "sortedEqual" predicate that compares two `Document`s and returns true if they
// have the same key/value pairs in them
public func sortedEqual(_ expectedValue: BSONDocument?) -> Predicate<BSONDocument> {
    Predicate.define("sortedEqual <\(stringify(expectedValue))>") { actualExpression, msg in
        let actualValue = try actualExpression.evaluate()

        guard let expected = expectedValue, let actual = actualValue else {
            if expectedValue == nil && actualValue != nil {
                return PredicateResult(
                    status: .fail,
                    message: msg.appendedBeNilHint()
                )
            }
            return PredicateResult(status: .fail, message: msg)
        }

        let matches = expected.sortedEquals(actual)
        return PredicateResult(status: PredicateStatus(bool: matches), message: msg)
    }
}

/// Prints a message if a server version or topology requirement is not met and a test is skipped
public func printSkipMessage(
    testName: String,
    unmetRequirement: UnmetRequirement
) {
    switch unmetRequirement {
    case let .minServerVersion(actual, required):
        print("Skipping test case \"\(testName)\": minimum required server " +
            "version \(required) not met by current server version \(actual)")

    case let .maxServerVersion(actual, required):
        print("Skipping test case \"\(testName)\": maximum required server " +
            "version \(required) not met by current server version \(actual)")

    case let .topology(actual, required):
        print("Skipping \(testName) due to unsupported topology type \(actual), supported topologies are: \(required)")
    }
}

public func unsupportedTopologyMessage(
    testName: String,
    topology: TopologyDescription.TopologyType = MongoSwiftTestCase.topologyType
)
    -> String {
    "Skipping \(testName) due to unsupported topology type \(topology)"
}

public func unsupportedServerVersionMessage(testName: String) -> String {
    "Skipping \(testName) due to unsupported server version."
}

extension TopologyDescription.TopologyType {
    /// Internal initializer used for translating evergreen config and spec test topologies to a `TopologyType`
    public init(from str: String) {
        switch str {
        case "sharded", "sharded_cluster":
            self = .sharded
        case "replicaset", "replica_set":
            self = .replicaSetWithPrimary
        default:
            self = .single
        }
    }
}

public struct TestError: LocalizedError {
    public let message: String
    public var errorDescription: String { self.message }

    public init(message: String) {
        self.message = message
    }
}

/// Makes `ServerAddress` `Decodable` for the sake of constructing it from spec test files.
extension ServerAddress: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hostPortPair = try container.decode(String.self)
        try self.init(hostPortPair)
    }
}

extension MongoError.CommandError {
    public static func new(
        code: MongoError.ServerErrorCode,
        codeName: String,
        message: String,
        errorLabels: [String]?
    ) -> MongoError.CommandError {
        MongoError.CommandError(
            code: code,
            codeName: codeName,
            message: message,
            errorLabels: errorLabels
        )
    }
}

extension CollectionSpecificationInfo {
    public static func new(readOnly: Bool, uuid: UUID? = nil) -> CollectionSpecificationInfo {
        CollectionSpecificationInfo(readOnly: readOnly, uuid: uuid)
    }
}

extension CollectionSpecification {
    public static func new(
        name: String,
        type: CollectionType,
        options: CreateCollectionOptions?,
        info: CollectionSpecificationInfo,
        idIndex: IndexModel?
    ) -> CollectionSpecification {
        CollectionSpecification(
            name: name,
            type: type,
            options: options,
            info: info,
            idIndex: idIndex
        )
    }
}

extension MongoError.WriteFailure {
    public static func new(
        code: MongoError.ServerErrorCode,
        codeName: String,
        message: String
    ) -> MongoError.WriteFailure {
        MongoError.WriteFailure(code: code, codeName: codeName, message: message)
    }
}

extension MongoError.WriteError {
    public static func new(
        writeFailure: MongoError.WriteFailure?,
        writeConcernFailure: MongoError.WriteConcernFailure?,
        errorLabels: [String]?
    ) -> MongoError.WriteError {
        MongoError.WriteError(
            writeFailure: writeFailure,
            writeConcernFailure: writeConcernFailure,
            errorLabels: errorLabels
        )
    }
}

extension BulkWriteResult {
    public static func new(
        deletedCount: Int? = nil,
        insertedCount: Int? = nil,
        insertedIDs: [Int: BSON]? = nil,
        matchedCount: Int? = nil,
        modifiedCount: Int? = nil,
        upsertedCount: Int? = nil,
        upsertedIDs: [Int: BSON]? = nil
    ) -> BulkWriteResult {
        BulkWriteResult(
            deletedCount: deletedCount ?? 0,
            insertedCount: insertedCount ?? 0,
            insertedIDs: insertedIDs ?? [:],
            matchedCount: matchedCount ?? 0,
            modifiedCount: modifiedCount ?? 0,
            upsertedCount: upsertedCount ?? 0,
            upsertedIDs: upsertedIDs ?? [:]
        )
    }
}

extension MongoError.BulkWriteFailure {
    public static func new(
        code: MongoError.ServerErrorCode,
        codeName: String,
        message: String,
        index: Int
    ) -> MongoError.BulkWriteFailure {
        MongoError.BulkWriteFailure(code: code, codeName: codeName, message: message, index: index)
    }
}

extension MongoError.BulkWriteError {
    public static func new(
        writeFailures: [MongoError.BulkWriteFailure]?,
        writeConcernFailure: MongoError.WriteConcernFailure?,
        otherError: Error?,
        result: BulkWriteResult?,
        errorLabels: [String]?
    ) -> MongoError.BulkWriteError {
        MongoError.BulkWriteError(
            writeFailures: writeFailures,
            writeConcernFailure: writeConcernFailure,
            otherError: otherError,
            result: result,
            errorLabels: errorLabels
        )
    }
}

extension InsertManyResult {
    public static func fromBulkResult(_ result: BulkWriteResult) -> InsertManyResult? {
        InsertManyResult(from: result)
    }
}
