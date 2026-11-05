"""Small cell decoder for asserting real fzf output in private PTYs."""
import codecs
import re
import unicodedata

class Cursor:
    def __init__(self, rows, columns=120):
        self.rows, self.columns, self.row, self.column = rows, columns, 0, 0
        self.grid = {}
        self.pending = ''
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.prefix, self.begin = '', None
        self.anchors = []
        self.synchronized = False

    def feed(self, data, elapsed):
        self.pending += self.decoder.decode(data)
        while self.pending:
            char = self.pending[0]
            if char == '\x1b':
                if len(self.pending) < 2: return
                if self.pending[1] == '[':
                    match = re.match(r'\x1b\[([0-?]*[ -/]*)([@-~])', self.pending)
                    if not match: return
                    parameters, final = match.groups()
                    self.pending = self.pending[len(match.group(0)):]
                    values = [int(v) if v.isdigit() else 0 for v in parameters.split(';')]
                    number = values[0] or 1
                    if final in 'Hf':
                        self.row = (values[0] or 1) - 1
                        self.column = (values[1] or 1) - 1 if len(values) > 1 else 0
                    elif final == 'A': self.row = max(0, self.row-number)
                    elif final == 'B': self.row = min(self.rows-1, self.row+number)
                    elif final == 'C': self.column += number
                    elif final == 'D': self.column = max(0, self.column-number)
                    elif final == 'G': self.column = number-1
                    elif final == 'd': self.row = number-1
                    elif final == 'K':
                        cells = self.grid.setdefault(self.row, {})
                        for column in list(cells):
                            if values[0] == 2 or (values[0] == 0 and column >= self.column) or (values[0] == 1 and column <= self.column):
                                cells.pop(column, None)
                    elif final == 'J' and values[0] in (2, 3): self.grid.clear()
                    elif final == 'h' and parameters == '?1049': self.row, self.column = 0, 0; self.grid.clear()
                    elif final in 'hl' and parameters == '?2026': self.synchronized = final == 'h'
                    continue
                if self.pending[1] in ']P_^':
                    end = re.search(r'\x07|\x1b\\', self.pending[2:])
                    if not end: return
                    self.pending = self.pending[end.end()+2:]
                    continue
                self.pending = self.pending[2:]
                continue
            self.pending = self.pending[1:]
            if char == '\r': self.column = 0; continue
            if char == '\n': self.row = min(self.rows-1, self.row+1); continue
            if ord(char) < 32: continue
            label = 'Enter switch'
            if label.startswith(self.prefix+char):
                if not self.prefix: self.begin = (self.row+1, self.column+1)
                self.prefix += char
                if self.prefix == label:
                    self.anchors.append({'ms': round(elapsed, 2), 'row': self.begin[0], 'column': self.begin[1], 'tty_rows': self.rows})
                    self.prefix = ''
            else: self.prefix = ''
            cells = 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1
            if 0 <= self.row < self.rows and self.column < self.columns:
                row = self.grid.setdefault(self.row, {})
                if cells:
                    row[self.column] = char
                    for offset in range(1, cells): row[self.column + offset] = ''
                elif self.column > 0: row[self.column - 1] = row.get(self.column - 1, '') + char
            self.column += cells

    def visible(self, first=0, last=None):
        return [''.join(self.grid.get(row, {}).get(column, ' ') for column in range(self.columns)).rstrip()
                for row in range(first, self.rows if last is None else last)]
