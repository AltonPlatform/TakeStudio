import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ImportedMovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try importReceivedMovie(from: received.file)
        }

        FileRepresentation(contentType: .mpeg4Movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try importReceivedMovie(from: received.file)
        }

        FileRepresentation(contentType: .quickTimeMovie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try importReceivedMovie(from: received.file)
        }

        FileRepresentation(contentType: .video) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try importReceivedMovie(from: received.file)
        }
    }

    private static func importReceivedMovie(from source: URL) throws -> ImportedMovieFile {
        let destination = TemporaryCaptureStore.videoURL()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return ImportedMovieFile(url: destination)
    }
}

struct ImportedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { image in
            SentTransferredFile(image.url)
        } importing: { received in
            let destination = TemporaryCaptureStore.photoURL()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

struct ImportedAudioFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .audio) { audio in
            SentTransferredFile(audio.url)
        } importing: { received in
            let destination = TemporaryCaptureStore.directoryURL
                .appendingPathComponent("import-\(UUID().uuidString).\(received.file.pathExtension)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}
