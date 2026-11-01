import 'dart:convert';

String prepareHongguoFixtureSource(String source) => source
    .replaceAll(
      '__THL_HONGGUO_SIGNING_ID_BASE64__',
      base64Encode(utf8.encode('test-sign')),
    )
    .replaceAll(
      '__THL_HONGGUO_SIGNING_MATERIAL_BASE64__',
      base64Encode(List<int>.generate(32, (index) => index + 1)),
    );
