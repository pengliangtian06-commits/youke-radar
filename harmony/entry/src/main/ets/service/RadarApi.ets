import { http } from '@kit.NetworkKit';
import { ApiError } from '../model/Types';

export class RadarApi {
  baseUrl: string = 'http://127.0.0.1:8000';

  async request<T>(path: string, method: http.RequestMethod = http.RequestMethod.GET,
    body: string = '', evaluation: boolean = false): Promise<T> {
    const connection = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: { 'Content-Type': 'application/json' },
        connectTimeout: 10000,
        readTimeout: evaluation ? 600000 : 90000,
        expectDataType: http.HttpDataType.STRING
      };
      if (body.length > 0) { options.extraData = body; }
      const response = await connection.request(this.baseUrl.replace(/\/$/, '') + path, options);
      if (response.responseCode >= 400) {
        let message: string = `请求失败（${response.responseCode}）`;
        try {
          const error = JSON.parse(response.result as string) as ApiError;
          message = typeof error.detail === 'string' ? error.detail : '填写的信息格式不正确，请检查日期和工时';
        } catch (_) { }
        throw new Error(message);
      }
      return JSON.parse(response.result as string) as T;
    } finally {
      connection.destroy();
    }
  }
}
