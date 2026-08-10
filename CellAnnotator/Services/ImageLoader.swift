//
//  ImageLoader.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum ImageLoader {
    enum LoadError: LocalizedError {
        case accessDenied
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Couldn't access the file. Try loading it again."
            case .decodeFailed:
                return "Could not decode this TIFF. It may be 16-bit or pyramidal."
            }
        }
    }
    
    static func loadFromBundle(_ name: String, ext: String = "tif") throws -> UIImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw LoadError.decodeFailed
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw LoadError.decodeFailed
        }
        return UIImage(cgImage: cgImage)
    }

    static func load(from url: URL) throws -> UIImage {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard didAccess else { throw LoadError.accessDenied }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw LoadError.decodeFailed
        }
        return UIImage(cgImage: cgImage)
    }
}
