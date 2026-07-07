import { textAtCursorMatchesToken } from './utils';

describe('textAtCursorMatchesToken', () => {
  test.concurrent.for([
    [
      ['#hashtag', 7, ['#']],
      [1, '#hashtag'],
    ],
    [
      ['#hash tag', 8, ['#']],
      [null, null],
    ],
    [
      [':+1', 2, [':']],
      [1, ':+1'],
    ],
    [
      [':-1', 2, [':']],
      [1, ':-1'],
    ],
    [
      ['#ハッシュタグ', 6, ['#']],
      [1, '#ハッシュタグ'],
    ],
    [
      ['#ハッシュ タグ', 7, ['#']],
      [null, null],
    ],
    [
      ['@testuser ', 10, ['@']],
      [null, null],
    ],
    [
      ['@testuser x', 11, ['@']],
      [null, null],
    ],
  ] as const)(
    'textAtCursorMatchesToken(%s) is %o',
    ([input, expected], { expect }) => {
      expect(
        textAtCursorMatchesToken(input[0], input[1], Array.from(input[2])),
      ).toStrictEqual(expected);
    },
  );
});
