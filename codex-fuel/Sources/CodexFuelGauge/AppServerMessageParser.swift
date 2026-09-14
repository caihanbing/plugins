import Foundation

enum AppServerEvent: Equatable {
    case initialized
    case rateLimitsResponse(id: Int, result: RateLimitsResult)
    case rateLimitsUpdated(bucket: LimitBucket)
    case error(id: Int?, message: String)
    case ignored
}

enum AppServerMessageParser {
    static func parse(_ data: Data) -> AppServerEvent {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .error(id: nil, message: "Codex 返回了无法解析的数据")
        }

        let id = integer(from: object["id"])

        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Codex App Server 请求失败"
            return .error(id: id, message: message)
        }

        if id == 0, object["result"] != nil {
            return .initialized
        }

        if
            let id,
            let result = object["result"] as? [String: Any],
            result["rateLimits"] != nil || result["rateLimitsByLimitId"] != nil
        {
            do {
                return .rateLimitsResponse(id: id, result: try RateLimitDecoding.decodeResult(from: result))
            } catch {
                return .error(id: id, message: "额度响应格式不兼容：\(error.localizedDescription)")
            }
        }

        if
            object["method"] as? String == "account/rateLimits/updated",
            let params = object["params"] as? [String: Any],
            let value = params["rateLimits"]
        {
            do {
                return .rateLimitsUpdated(bucket: try RateLimitDecoding.decodeBucket(from: value))
            } catch {
                return .error(id: nil, message: "实时额度通知格式不兼容：\(error.localizedDescription)")
            }
        }

        return .ignored
    }

    private static func integer(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }
}
