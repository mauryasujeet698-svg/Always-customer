import 'package:flutter_test/flutter_test.dart';
import 'package:allways_app/main.dart';

void main() {
  group('cloudinaryImageUrl', () {
    test('returns blank and non-Cloudinary URLs unchanged', () {
      expect(cloudinaryImageUrl('', width: 300, height: 200), '');
      const url = 'https://example.com/image.jpg';
      expect(cloudinaryImageUrl(url, width: 300, height: 200), url);
    });

    test('adds responsive transformation to a Cloudinary image URL', () {
      expect(
        cloudinaryImageUrl(
          'https://res.cloudinary.com/demo/image/upload/sample.jpg',
          width: 300,
          height: 200,
        ),
        'https://res.cloudinary.com/demo/image/upload/w_300,h_200,c_fill,g_auto,f_auto,q_auto,e_sharpen:100/sample.jpg',
      );
    });

    test('does not stack ALLways transformations on an already transformed URL', () {
      expect(
        cloudinaryImageUrl(
          'https://res.cloudinary.com/demo/image/upload/w_100,h_100,c_fill/sample.jpg',
          width: 300,
          height: 200,
        ),
        'https://res.cloudinary.com/demo/image/upload/w_300,h_200,c_fill,g_auto,f_auto,q_auto,e_sharpen:100/sample.jpg',
      );
    });
  });
}
