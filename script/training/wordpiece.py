"""The app's uncased, accent-stripped WordPiece tokenizer in Python, exactly as `BertWordPieceTokenizer` splits text.
Shared by the pair-model training (`train_pair_model.py`) and the pretraining data builder (`pretrain_pairs.py`, #623);
it needs no torch, so `test.sh` can run the builder's self-check with the system Python.
"""
import pathlib
import unicodedata

VOCAB = pathlib.Path(__file__).resolve().parents[2] / 'Sources/Resources/Models/vocab.txt'
MAX_LENGTH = 256


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Tokenizer:
    """Uncased, accent-stripped WordPiece exactly as the app's `BertWordPieceTokenizer` splits text."""

    def __init__(self, path=VOCAB):
        self.vocab = {}
        for index, line in enumerate(path.read_text(encoding='utf-8').split('\n')):
            if line.strip():
                self.vocab[line.strip()] = index
        self.pad, self.unk = self.vocab.get('[PAD]', 0), self.vocab.get('[UNK]', 100)
        self.cls, self.sep = self.vocab.get('[CLS]', 101), self.vocab.get('[SEP]', 102)

    @staticmethod
    def words(text):
        folded = ''.join(c for c in unicodedata.normalize('NFD', text) if unicodedata.category(c) != 'Mn').lower()
        words, current = [], ''
        for char in folded:
            if char.isspace():
                words, current = words + [current] if current else words, ''
            elif unicodedata.category(char)[0] in 'PS':
                words, current = (words + [current] if current else words) + [char], ''
            else:
                current += char
        return words + [current] if current else words

    def pieces(self, text):
        ids = []
        for word in self.words(text):
            ids.extend(self.word_piece(word))
        return ids

    def word_piece(self, word):
        if len(word) > 100:
            return [self.unk]
        ids, start = [], 0
        while start < len(word):
            end = len(word)
            while start < end and (('##' if start else '') + word[start:end]) not in self.vocab:
                end -= 1
            if start == end:
                return [self.unk]
            ids.append(self.vocab[('##' if start else '') + word[start:end]])
            start = end
        return ids

    def encode_single(self, text, max_length=128):
        return [self.cls] + self.pieces(text)[:max_length - 2] + [self.sep]

    def encode_pair(self, a, b, max_length=MAX_LENGTH):
        return self.encode_ids(self.pieces(a), self.pieces(b), max_length)

    def encode_ids(self, pa, pb, max_length=MAX_LENGTH):
        """[CLS] a [SEP] b [SEP], longest first truncation (b on ties), padded; ids, mask, type ids."""
        pa, pb = list(pa), list(pb)
        while len(pa) + len(pb) > max_length - 3:
            (pa if len(pa) > len(pb) else pb).pop()
        ids = [self.cls] + pa + [self.sep] + pb + [self.sep]
        types = [0] * (len(pa) + 2) + [1] * (len(pb) + 1)
        padding = max_length - len(ids)
        return ids + [self.pad] * padding, [1] * len(ids) + [0] * padding, types + [0] * padding


def pair_prefix(gap_hours=None, same_publisher=None):
    """The words the pair model reads in front of each text (#626), identical to `EventMatcher.pairModelInput` in
    Swift: the pair's time gap and whether one publisher wrote both, "unknown" where the data has neither."""
    gap = 'gap unknown' if gap_hours is None else f'gap {round(gap_hours)} hours'
    if same_publisher is None:
        publisher = 'publishers unknown'
    else:
        publisher = 'same publisher' if same_publisher else 'different publishers'
    return f'{gap}; {publisher}. '
