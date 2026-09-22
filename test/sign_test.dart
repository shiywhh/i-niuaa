// 签名函数测试：向量由网页 chunk-7d526474 模块 89eb 的算法在同条件下
// 用 node crypto 预先算出（固定 timestamp/nonce，假 token）。
import 'package:nuaa_eams/core/card_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('signPayload 与网页 JS 口径一致（排序/跳过空值/大写 SHA256）', () {
    final signed = CardClient.signPayload({
      'feeitemid': '401',
      'appid': '56321',
      'tranamt': 0.01,
      'source': 'app',
      'synjones-auth': 'bearer TESTTOKEN',
      'yktcard': '999999',
      'synAccessSource': 'h5',
      'abstracts': '{"type":"recharge"}',
    }, timestamp: '20260922165717', nonce: 'unittest01');

    expect(signed['APP_ID'], '56321');
    expect(signed['TIMESTAMP'], '20260922165717');
    expect(signed['SIGN_TYPE'], 'SHA256');
    expect(signed['NONCE'], 'unittest01');
    expect(
      signed['SIGN'],
      '3F058C136F507D714C6D2137F8C9260E4592CD4BA9230FC1B380A53197FDB29B',
    );
  });

  test('signPayload 整数金额不带小数点、注入字段不可覆盖', () {
    final signed = CardClient.signPayload({
      'tranamt': 10.0,
      // 试图伪造注入字段：外层同名键会被固定值覆盖
      'APP_ID': '99999',
      'SIGN': 'FAKE',
    }, timestamp: '20260101010101', nonce: 'n');

    expect(signed['tranamt'], '10');
    expect(signed['APP_ID'], '56321');
    expect(signed['SIGN'], isNot('FAKE'));
  });
}
