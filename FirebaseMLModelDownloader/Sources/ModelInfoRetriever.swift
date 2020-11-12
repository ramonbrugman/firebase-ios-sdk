// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import FirebaseCore
import FirebaseInstallations

struct ModelInfoResponse: Codable {
  var downloadURL: String
  var expireTime: String
  var size: String
}

extension ModelInfoResponse {
  enum CodingKeys: String, CodingKey {
    case downloadURL = "downloadUri"
    case expireTime
    case size = "sizeBytes"
  }
}

/// Model info retriever for a model from local user defaults or server.
class ModelInfoRetriever: NSObject {
  /// Current Firebase app.
  var app: FirebaseApp
  /// Model info associated with model.
  var modelInfo: ModelInfo?
  /// Model name.
  var modelName: String
  /// Firebase installations.
  var installations: Installations

  /// Associate model info retriever with current Firebase app, and model name.
  init(app: FirebaseApp, modelName: String) {
    self.app = app
    self.modelName = modelName
    installations = Installations.installations(app: app)
  }

  /// Build custom model object from model info.
  func buildModel() -> CustomModel? {
    /// Build custom model only if model info is filled out, and model file is already on device.
    guard let info = modelInfo, let path = info.path else { return nil }
    let model = CustomModel(
      name: info.name,
      size: info.size,
      path: path,
      hash: info.hash
    )
    return model
  }
}

/// Extension to handle fetching model info from server.
extension ModelInfoRetriever {
  /// HTTP request headers.
  static let fisTokenHTTPHeader: String = "x-goog-firebase-installations-auth"
  static let hashMatchHTTPHeader: String = "if-none-match"
  static let bundleIDHTTPHeader: String = "x-ios-bundle-identifier"

  /// HTTP response headers.
  static let etagHTTPHeader: String = "Etag"

  /// Error descriptions.
  static let tokenErrorDescription: String = "Error retrieving FIS token."
  static let selfDeallocatedErrorDescription: String = "Self deallocated."
  static let missingModelHashErrorDescription: String = "Model hash missing in server response."
  static let invalidHTTPResponseErrorDescription: String =
    "Could not get a valid HTTP response from server."

  /// Construct model fetch base URL.
  var modelInfoFetchURL: URL {
    let projectID = app.options.projectID ?? ""
    let apiKey = app.options.apiKey
    var components = URLComponents()
    components.scheme = "https"
    components.host = "firebaseml.googleapis.com"
    components.path = "/v1beta2/projects/\(projectID)/models/\(modelName):download"
    components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
    return components.url!
  }

  /// Construct model fetch URL request.
  func getModelInfoFetchURLRequest(token: String) -> URLRequest {
    var request = URLRequest(url: modelInfoFetchURL)
    request.httpMethod = "GET"
    // TODO: Check if bundle ID needs to be part of the request header.
    let bundleID = Bundle.main.bundleIdentifier ?? ""
    request.setValue(bundleID, forHTTPHeaderField: ModelInfoRetriever.bundleIDHTTPHeader)
    request.setValue(token, forHTTPHeaderField: ModelInfoRetriever.fisTokenHTTPHeader)
    if let info = modelInfo, info.hash.count > 0 {
      request.setValue(info.hash, forHTTPHeaderField: ModelInfoRetriever.hashMatchHTTPHeader)
    }
    return request
  }

  /// Get model info from server.
  func downloadModelInfo(completion: @escaping (DownloadError?) -> Void) {
    /// Get FIS token.
    installations.authToken { [weak self] tokenResult, error in
      guard let self = self else {
        completion(.internalError(description: ModelInfoRetriever.selfDeallocatedErrorDescription))
        return
      }
      guard let result = tokenResult
      else {
        completion(.internalError(description: ModelInfoRetriever.tokenErrorDescription))
        return
      }
      /// Get model info fetch URL with appropriate HTTP headers.
      let request = self.getModelInfoFetchURLRequest(token: result.authToken)

      /// Download model info.
      // TODO: Consider moving request to a separate method
      let dataTask = URLSession.shared.dataTask(with: request) { [weak self]
        data, response, error in
        guard let self = self else {
          completion(.internalError(description: ModelInfoRetriever
              .selfDeallocatedErrorDescription))
          return
        }
        if let downloadError = error {
          completion(.internalError(description: downloadError.localizedDescription))
        } else {
          guard let httpResponse = response as? HTTPURLResponse else {
            completion(.internalError(description: ModelInfoRetriever
                .invalidHTTPResponseErrorDescription))
            return
          }

          switch httpResponse.statusCode {
          case 200:
            guard let modelHash = httpResponse
              .allHeaderFields[ModelInfoRetriever.etagHTTPHeader] as? String else {
              completion(.internalError(description: ModelInfoRetriever
                  .missingModelHashErrorDescription))
              return
            }

            guard let data = data else {
              completion(.internalError(description: ModelInfoRetriever
                  .invalidHTTPResponseErrorDescription))
              return
            }
            self.saveModelInfo(data: data, modelHash: modelHash)
            completion(nil)
          case 304:
            completion(nil)
          case 404:
            completion(.notFound)
          // TODO: Handle more http status codes
          default:
            completion(
              .internalError(
                description: "Server returned with error - \(httpResponse.statusCode)."
              )
            )
          }
        }
      }
      dataTask.resume()
    }
  }

  /// Save model info to user defaults.
  func saveModelInfo(data: Data, modelHash: String) {
    // TODO: Save model info to user defaults
    let decoder = JSONDecoder()
    guard let modelInfoJSON = try? decoder.decode(ModelInfoResponse.self, from: data)
    else { return }
    modelInfo = ModelInfo(app: app, name: modelName)
    modelInfo?.downloadURL = modelInfoJSON.downloadURL
    modelInfo?.size = Int(modelInfoJSON.size)!
    modelInfo?.hash = modelHash
  }
}