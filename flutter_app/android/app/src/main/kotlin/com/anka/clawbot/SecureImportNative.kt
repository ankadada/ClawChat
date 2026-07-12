package com.anka.clawbot

/** JNI-only security broker. Absence of the native library fails imports closed. */
object SecureImportNative {
    init {
        System.loadLibrary("secure_import")
    }

    external fun importHostFile(
        sourcePath: String,
        uploadsPath: String,
        finalName: String,
        operationId: String,
        maxBytes: Long
    ): Array<String>

    external fun readFileBounded(
        rootPath: String,
        relativePath: String,
        operationId: String,
        maxBytes: Long
    ): ByteArray?

    external fun cancelOperation(operationId: String)
    external fun finishOperation(operationId: String)
    external fun acknowledgeImport(
        uploadsPath: String,
        finalName: String,
        operationId: String,
        expectedSize: Long,
        expectedSha256: String
    )
    external fun discardImport(
        uploadsPath: String,
        finalName: String,
        operationId: String,
        expectedSize: Long,
        expectedSha256: String
    )
    external fun reconcileImports(uploadsPath: String)
    external fun listPendingImports(uploadsPath: String, maxEntries: Int): Array<String>
}
