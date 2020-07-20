import CLibMongoC

/// Class representing a connection string for connecting to MongoDB.
internal class ConnectionString {
    /// Pointer to the underlying `mongoc_uri_t`.
    private let _uri: OpaquePointer

    /// Initializes a new `ConnectionString` with the provided options.
    internal init(_ connectionString: String, options: MongoClientOptions? = nil) throws {
        var error = bson_error_t()
        guard let uri = mongoc_uri_new_with_error(connectionString, &error) else {
            throw extractMongoError(error: error)
        }
        self._uri = uri

        try self.applyAndValidateOptions(options)
    }

    /// This method applies various options set in the options struct the underlying `mongoc_uri_t`. In addition, it
    /// performs extra validation that libmongoc fails to perform. See CDRIVER-3723 for details.
    // swiftlint:disable:next cyclomatic_complexity
    private func applyAndValidateOptions(_ options: MongoClientOptions?) throws {
        try self.applyAndValidateConnectionPoolOptions(options)
        try self.applyAndValidateCompressionOptions(options)
        try self.applyAndValidateTLSOptions(options)
        try self.applyAndValidateDirectConnection(options)
        try self.applyAndValidateAuthOptions(options)

        if let appName = options?.appName {
            guard mongoc_uri_set_option_as_utf8(self._uri, MONGOC_URI_APPNAME, appName) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set appName to \(appName)")
            }
        }

        if let heartbeatFreqMS = options?.heartbeatFrequencyMS {
            guard let value = Int32(exactly: heartbeatFreqMS), value >= 500 else {
                throw MongoError.InvalidArgumentError(
                    message: "Invalid heartbeatFrequencyMS \(heartbeatFreqMS): must be between 500 and \(Int32.max)"
                )
            }

            guard mongoc_uri_set_option_as_int32(self._uri, MONGOC_URI_HEARTBEATFREQUENCYMS, value) else {
                throw MongoError.InvalidArgumentError(
                    message: "Failed to set heartbeatFrequencyMS to \(value)"
                )
            }
        }

        let invalidThresholdMsg = "Invalid localThresholdMS %d: must be between 0 and \(Int32.max)"
        if let localThresholdMS = options?.localThresholdMS {
            guard let value = Int32(exactly: localThresholdMS), value >= 0 else {
                throw MongoError.InvalidArgumentError(message: String(format: invalidThresholdMsg, localThresholdMS))
            }

            guard mongoc_uri_set_option_as_int32(self._uri, MONGOC_URI_LOCALTHRESHOLDMS, value) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set localThresholdMS to \(value)")
            }
            // libmongoc does not validate an invalid value for localThresholdMS set via URI. if it was set that way and
            // not overridden via options struct, validate it ourselves here.
        } else if let uriValue = self.options?[MONGOC_URI_LOCALTHRESHOLDMS]?.int32Value, uriValue < 0 {
            throw MongoError.InvalidArgumentError(message: String(format: invalidThresholdMsg, uriValue))
        }

        if let rc = options?.readConcern {
            self.readConcern = rc
        }

        if let rp = options?.readPreference {
            self.readPreference = rp
        }

        if let replicaSet = options?.replicaSet {
            guard mongoc_uri_set_option_as_utf8(self._uri, MONGOC_URI_REPLICASET, replicaSet) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set replicaSet to \(replicaSet)")
            }
        }

        if let rr = options?.retryReads {
            guard mongoc_uri_set_option_as_bool(self._uri, MONGOC_URI_RETRYREADS, rr) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set retryReads to \(rr)")
            }
        }

        if let rw = options?.retryWrites {
            guard mongoc_uri_set_option_as_bool(self._uri, MONGOC_URI_RETRYWRITES, rw) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set retryWrites to \(rw)")
            }
        }

        let invalidSSTimeoutMsg = "Invalid serverSelectionTimeoutMS %d: must be between 1 and \(Int32.max)"
        if let ssTimeout = options?.serverSelectionTimeoutMS {
            guard let value = Int32(exactly: ssTimeout), value > 0 else {
                throw MongoError.InvalidArgumentError(message: String(format: invalidSSTimeoutMsg, ssTimeout))
            }

            guard mongoc_uri_set_option_as_int32(self._uri, MONGOC_URI_SERVERSELECTIONTIMEOUTMS, value) else {
                throw MongoError.InvalidArgumentError(
                    message: "Failed to set serverSelectionTimeoutMS to \(value)"
                )
            }
        } else if let uriValue = self.options?[MONGOC_URI_SERVERSELECTIONTIMEOUTMS]?.int32Value, uriValue <= 0 {
            throw MongoError.InvalidArgumentError(message: String(format: invalidSSTimeoutMsg, uriValue))
        }

        if let wc = options?.writeConcern {
            self.writeConcern = wc
        }
    }

    private func applyAndValidateCompressionOptions(_ options: MongoClientOptions?) throws {
        if let compressors = options?.compressors {
            // user specified an empty array, so we should nil out any compressors set via connection string.
            guard !compressors.isEmpty else {
                guard mongoc_uri_set_compressors(self._uri, nil) else {
                    throw MongoError.InvalidArgumentError(message: "Failed to set compressors to nil")
                }
                return
            }

            // otherwise, the only valid inputs is a length 1 array containing either zlib or zlib with a level.
            guard compressors.count == 1 else {
                throw MongoError.InvalidArgumentError(message: "zlib compressor provided multiple times")
            }

            let compressor = compressors[0]
            switch compressor._compressor {
            case let .zlib(level):
                guard mongoc_uri_set_compressors(self._uri, "zlib") else {
                    throw MongoError.InvalidArgumentError(message: "Failed to set compressor to zlib")
                }

                if let level = level {
                    guard mongoc_uri_set_option_as_int32(self._uri, MONGOC_URI_ZLIBCOMPRESSIONLEVEL, level) else {
                        throw MongoError.InvalidArgumentError(message:
                            "Failed to set zLibCompressionLevel to \(level)"
                        )
                    }
                }
            }
        }
    }

    private func applyAndValidateConnectionPoolOptions(_ options: MongoClientOptions?) throws {
        if let maxPoolSize = options?.maxPoolSize {
            guard let value = Int32(exactly: maxPoolSize), value > 0 else {
                throw MongoError.InvalidArgumentError(
                    message: "Invalid maxPoolSize \(maxPoolSize): must be between 1 and \(Int32.max)"
                )
            }
            guard mongoc_uri_set_option_as_int32(self._uri, MONGOC_URI_MAXPOOLSIZE, value) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set maxPoolSize to \(value)")
            }
        }

        // the way libmongoc has implemented this option is not in line with the way users would expect a minPoolSize
        // option to behave. throw an error if we detect it to prevent users from inadvertently using it.
        // once we own our own connection pool we will implement this option correctly.
        // see: http://mongoc.org/libmongoc/current/mongoc_client_pool_min_size.html
        guard !self.hasOption(MONGOC_URI_MINPOOLSIZE) else {
            throw MongoError.InvalidArgumentError(message: "Unsupported connection string option minPoolSize")
        }

        // libmongoc has reserved all of these as known options keywords so no warnings are generated, however they
        // actually have no effect, so we should prevent users from trying to use them.
        if self.hasOption(MONGOC_URI_MAXIDLETIMEMS) {
            throw MongoError.InvalidArgumentError(message: "Unsupported connection string option maxIdleTimeMS")
        }
        if self.hasOption(MONGOC_URI_WAITQUEUEMULTIPLE) {
            throw MongoError.InvalidArgumentError(message: "Unsupported connection string option waitQueueMultiple")
        }
        if self.hasOption(MONGOC_URI_WAITQUEUEMULTIPLE) {
            throw MongoError.InvalidArgumentError(message: "Unsupported connection string option waitQueueTimeoutMS")
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func applyAndValidateTLSOptions(_ options: MongoClientOptions?) throws {
        if let tls = options?.tls {
            // per URI options spec, we must raise an error if all instances of tls and ssl do not have the same value.
            // we don't allow setting `ssl`  via options struct, so we only need to worry about this particular
            // combination. if clashing values are provided in the input connection string, libmongoc will error.
            if let uriSSL = self.options?[MONGOC_URI_SSL]?.boolValue {
                guard uriSSL == tls else {
                    throw MongoError.InvalidArgumentError(
                        message: "ssl and tls options cannot both be specified with different values: " +
                            "got ssl=\(uriSSL), tls=\(tls)"
                    )
                }
            }

            guard mongoc_uri_set_option_as_bool(self._uri, MONGOC_URI_TLS, tls) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set tls to \(tls)")
            }
        }

        if options?.tlsInsecure != nil || self.hasOption(MONGOC_URI_TLSINSECURE) {
            // per URI options spec, we must raise an error if tlsInsecure is provided along with either of
            // tlsAllowInvalidCertificates or tlsAllowInvalidHostnames. if such a combination is provided in the
            // input connection string, libmongoc will error.
            if options?.tlsAllowInvalidCertificates != nil || self.hasOption(MONGOC_URI_TLSALLOWINVALIDCERTIFICATES) {
                throw MongoError.InvalidArgumentError(
                    message: "tlsInsecure and tlsAllowInvalidCertificates options cannot both be specified"
                )
            }

            if options?.tlsAllowInvalidHostnames != nil || self.hasOption(MONGOC_URI_TLSALLOWINVALIDHOSTNAMES) {
                throw MongoError.InvalidArgumentError(
                    message: "tlsInsecure and tlsAllowInvalidHostnames options cannot both be specified"
                )
            }

            if let tlsInsecure = options?.tlsInsecure {
                guard mongoc_uri_set_option_as_bool(self._uri, MONGOC_URI_TLSINSECURE, tlsInsecure) else {
                    throw MongoError.InvalidArgumentError(
                        message: "Failed to set tlsInsecure to \(tlsInsecure)"
                    )
                }
            }
        }

        if let invalidCerts = options?.tlsAllowInvalidCertificates {
            guard mongoc_uri_set_option_as_bool(self._uri, MONGOC_URI_TLSALLOWINVALIDCERTIFICATES, invalidCerts) else {
                throw MongoError.InvalidArgumentError(
                    message: "Failed to set tlsAllowInvalidCertificates to \(invalidCerts)"
                )
            }
        }

        if let invalidHostnames = options?.tlsAllowInvalidHostnames {
            guard mongoc_uri_set_option_as_bool(
                self._uri,
                MONGOC_URI_TLSALLOWINVALIDHOSTNAMES,
                invalidHostnames
            ) else {
                throw MongoError.InvalidArgumentError(
                    message: "Failed to set tlsAllowInvalidHostnames to \(invalidHostnames)"
                )
            }
        }

        if let caFile = options?.tlsCAFile?.absoluteString {
            guard mongoc_uri_set_option_as_utf8(self._uri, MONGOC_URI_TLSCAFILE, caFile) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set tlsCAFile to \(caFile)")
            }
        }

        if let certFile = options?.tlsCertificateKeyFile?.absoluteString {
            guard mongoc_uri_set_option_as_utf8(self._uri, MONGOC_URI_TLSCERTIFICATEKEYFILE, certFile) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set tlsCertificateKeyFile to \(certFile)")
            }
        }

        if let password = options?.tlsCertificateKeyFilePassword {
            guard mongoc_uri_set_option_as_utf8(self._uri, MONGOC_URI_TLSCERTIFICATEKEYFILEPASSWORD, password) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set tlsCertificateKeyPassword")
            }
        }
    }

    private func applyAndValidateDirectConnection(_ options: MongoClientOptions?) throws {
        // Per SDAM spec: If the ``directConnection`` option is not specified, newly developed drivers MUST behave as
        // if it was specified with the false value.
        if let dc = options?.directConnection {
            guard !(dc && self.usesDNSSeedlistFormat) else {
                throw MongoError.InvalidArgumentError(
                    message: "directConnection=true is incompatible with mongodb+srv connection strings"
                )
            }

            guard mongoc_uri_set_option_as_bool(self._uri, MONGOC_URI_DIRECTCONNECTION, dc) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set directConnection to \(dc)")
            }
        } else if !self.hasOption("directConnection") {
            guard mongoc_uri_set_option_as_bool(self._uri, MONGOC_URI_DIRECTCONNECTION, false) else {
                throw MongoError.InvalidArgumentError(message: "Failed to set directConnection to false")
            }
        }
    }

    /// Sets credential properties in the URI string
    private func applyAndValidateAuthOptions(_ options: MongoClientOptions?) throws {
        guard let credential = options?.credential else {
            return
        }

        if let username = credential.username {
            guard mongoc_uri_set_username(self._uri, username) else {
                throw MongoError.InvalidArgumentError(message: "Cannot set username to \(username).")
            }
        }

        if let password = credential.password {
            guard mongoc_uri_set_password(self._uri, password) else {
                throw MongoError.InvalidArgumentError(message: "Cannot set password.")
            }
        }

        if let authSource = credential.source {
            guard mongoc_uri_set_auth_source(self._uri, authSource) else {
                throw MongoError.InvalidArgumentError(message: "Cannot set authSource to \(authSource).")
            }
        }

        if let mechanism = credential.mechanism {
            guard mongoc_uri_set_auth_mechanism(self._uri, mechanism.name) else {
                throw MongoError.InvalidArgumentError(message: "Cannot set mechanism to \(mechanism)).")
            }
        }

        try credential.mechanismProperties?.withBSONPointer { mechanismPropertiesPtr in
            guard mongoc_uri_set_mechanism_properties(self._uri, mechanismPropertiesPtr) else {
                throw MongoError.InvalidArgumentError(
                    message: "Cannot set mechanismProperties to \(String(describing: credential.mechanismProperties))."
                )
            }
        }
    }

    /// Initializes a new connection string that wraps a copy of the provided URI. Does not destroy the input URI.
    internal init(copying uri: OpaquePointer) {
        self._uri = mongoc_uri_copy(uri)
    }

    /// Cleans up the underlying `mongoc_uri_t`.
    deinit {
        mongoc_uri_destroy(self._uri)
    }

    /// The `ReadConcern` for this connection string.
    internal var readConcern: ReadConcern {
        get {
            ReadConcern(copying: mongoc_uri_get_read_concern(self._uri))
        }
        set(rc) {
            rc.withMongocReadConcern { rcPtr in
                mongoc_uri_set_read_concern(self._uri, rcPtr)
            }
        }
    }

    /// The `WriteConcern` for this connection string.
    internal var writeConcern: WriteConcern {
        get {
            WriteConcern(copying: mongoc_uri_get_write_concern(self._uri))
        }
        set(wc) {
            wc.withMongocWriteConcern { wcPtr in
                mongoc_uri_set_write_concern(self._uri, wcPtr)
            }
        }
    }

    /// The `ReadPreference` for this connection string.
    internal var readPreference: ReadPreference {
        get {
            ReadPreference(copying: mongoc_uri_get_read_prefs_t(self._uri))
        }
        set(rp) {
            rp.withMongocReadPreference { rpPtr in
                mongoc_uri_set_read_prefs_t(self._uri, rpPtr)
            }
        }
    }

    /// Returns the username if one was provided, otherwise nil.
    internal var username: String? {
        guard let username = mongoc_uri_get_username(self._uri) else {
            return nil
        }
        return String(cString: username)
    }

    /// Returns the password if one was provided, otherwise nil.
    internal var password: String? {
        guard let pw = mongoc_uri_get_password(self._uri) else {
            return nil
        }
        return String(cString: pw)
    }

    /// Returns the auth database if one was provided, otherwise nil.
    internal var authSource: String? {
        guard let source = mongoc_uri_get_auth_source(self._uri) else {
            return nil
        }
        return String(cString: source)
    }

    /// Returns the auth mechanism if one was provided, otherwise nil.
    internal var authMechanism: MongoCredential.Mechanism? {
        guard let mechanism = mongoc_uri_get_auth_mechanism(self._uri) else {
            return nil
        }
        let str = String(cString: mechanism)
        return MongoCredential.Mechanism(str)
    }

    /// Returns a document containing the auth mechanism properties if any were provided, otherwise nil.
    internal var authMechanismProperties: BSONDocument? {
        var props = bson_t()
        return withUnsafeMutablePointer(to: &props) { propsPtr in
            guard mongoc_uri_get_mechanism_properties(self._uri, propsPtr) else {
                return nil
            }
            /// This copy should not be returned directly as its only guaranteed valid for as long as the
            /// `mongoc_uri_t`, as `props` was statically initialized from data stored in the URI and may contain
            /// pointers that will be invalidated once the URI is.
            let copy = BSONDocument(copying: propsPtr)

            return copy.mapValues { value in
                // mongoc returns boolean options e.g. CANONICALIZE_HOSTNAME as strings, but they are boolean values.
                switch value {
                case "true":
                    return true
                case "false":
                    return false
                default:
                    return value
                }
            }
        }
    }

    /// Returns the credential configured on this URI. Will be empty if no options are set.
    internal var credential: MongoCredential {
        MongoCredential(
            username: self.username,
            password: self.password,
            source: self.authSource,
            mechanism: self.authMechanism,
            mechanismProperties: self.authMechanismProperties
        )
    }

    internal var db: String? {
        guard let db = mongoc_uri_get_database(self._uri) else {
            return nil
        }
        return String(cString: db)
    }

    /// Returns a document containing all of the options provided after the ? of the URI.
    internal var options: BSONDocument? {
        guard let optsDoc = mongoc_uri_get_options(self._uri) else {
            return nil
        }
        var copy = BSONDocument(copying: optsDoc)

        if let authSource = self.authSource {
            copy.authsource = .string(authSource)
        }
        if let authMechanism = self.authMechanism {
            copy.authmechanism = .string(authMechanism.name)
        }
        if let authMechanismProperties = self.authMechanismProperties {
            copy.authmechanismproperties = .document(authMechanismProperties)
        }
        if let parsedTagSets = self.readPreference.tagSets {
            copy.readpreferencetags = .array(parsedTagSets.map { BSON.document($0) })
        }
        if let compressors = self.compressors {
            copy.compressors = .array(compressors.map { .string($0) })
        }
        if let readConcern = self.readConcern.level {
            copy.readconcernlevel = .string(readConcern)
        }

        return copy
    }

    /// Returns the host/port pairs specified in the connection string, or nil if this connection string's scheme is
    /// “mongodb+srv://”.
    internal var hosts: [ServerAddress]? {
        guard let hostList = mongoc_uri_get_hosts(self._uri) else {
            return nil
        }

        var hosts = [ServerAddress]()
        var next = hostList

        while true {
            hosts.append(ServerAddress(next))

            guard let nextPointer = next.pointee.next else {
                break
            }
            next = UnsafePointer(nextPointer)
        }

        return hosts
    }

    internal var compressors: [String]? {
        guard let compressors = mongoc_uri_get_compressors(self._uri) else {
            return nil
        }
        return BSONDocument(copying: compressors).keys
    }

    internal var replicaSet: String? {
        guard let rs = mongoc_uri_get_replica_set(self._uri) else {
            return nil
        }
        return String(cString: rs)
    }

    internal var appName: String? {
        guard let appName = mongoc_uri_get_option_as_utf8(self._uri, MONGOC_URI_APPNAME, nil) else {
            return nil
        }
        return String(cString: appName)
    }

    internal var usesDNSSeedlistFormat: Bool {
        // This method returns a string if this URI’s scheme is “mongodb+srv://”, or NULL if the scheme is
        // “mongodb://”.
        mongoc_uri_get_service(self._uri) != nil
    }

    private func hasOption(_ option: String) -> Bool {
        mongoc_uri_has_option(self._uri, option)
    }

    /// Executes the provided closure using a pointer to the underlying `mongoc_uri_t`.
    internal func withMongocURI<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try body(self._uri)
    }
}
