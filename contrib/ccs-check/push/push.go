// Package push: the backend's push, a tar of the files that changed (contrib/ccs-push), received
// into the gate's staging folder, and the gate's own copies between staging and the live site,
// in place of rsync: no C parses what the backend sends. A push holds plain files and folders
// only, at clean paths under the folder; anything else refuses all of it.
package push

import (
	"archive/tar"
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

// Limits: a push's bytes (its files', together), one file's, and how many entries
type Limits struct {
	Total, File int64
	Entries     int
}

// Default: a whole site is about 100 MB; a page over 2 MB isn't checked, an image over 8 MB isn't
// read for QR codes (the gate holds them back), so these only bound the disk and the time
var Default = Limits{Total: 512 << 20, File: 64 << 20, Entries: 100000}

// counter: the stream's bytes, headers too
type counter struct {
	r   io.Reader
	n   int64
	max int64
}

func (c *counter) Read(p []byte) (int, error) {
	if c.n >= c.max {
		return 0, errors.New("over its size limit")
	}
	if int64(len(p)) > c.max-c.n {
		p = p[:c.max-c.n]
	}
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}

// temp: the start of a file's name while it is written (write): never a name of the site's, and
// one left by a copy that was killed is removed by the next (review 10's L-3)
const temp = ".ccs-push-"

// Name: a tar entry's name as a path under the folder ("./a/b", "a/b/" read as "a/b"), or why it
// isn't one: absolute, a "." or ".." step, an empty step, a control character, too long
func Name(n string) (string, error) {
	q := strings.TrimSuffix(strings.TrimPrefix(n, "./"), "/")
	switch {
	case q == "" || len(q) > 4096:
		return "", fmt.Errorf("a name that is empty or too long")
	case strings.IndexFunc(q, func(r rune) bool { return r < 0x20 || r == 0x7f }) >= 0:
		return "", fmt.Errorf("a name with a control character in it")
	case strings.Contains(q, `\`):
		return "", fmt.Errorf("a name with a backslash in it (%q)", q)
	case path.Clean(q) != q || !filepath.IsLocal(q):
		return "", fmt.Errorf("a name that isn't a clean path under the site (%q)", q)
	}
	for _, s := range strings.Split(q, "/") {
		if len(s) > 255 {
			return "", fmt.Errorf("a name with a part over 255 bytes")
		}
		if strings.HasPrefix(s, temp) {
			return "", fmt.Errorf("a name starting %s (the gate's own while it writes)", temp)
		}
	}
	return q, nil
}

// Receive: the tar on r written into dir, each file as a new file renamed into place (so a file
// dir shares with another folder is never written through), 644, the folders it needs 755; the
// names of the files written. A folder entry makes nothing (a folder holding no file would go
// live and stand where a page may come later: review 10's M-1). A file where dir has an empty
// folder takes its place. Any entry but a plain file or folder (a link of either kind, a device,
// a FIFO), a name that isn't one (Name), a name twice, a file where dir has a folder with
// something in it or a folder where it has a file, a broken stream or one past lim: an error, and
// the push is refused (what was written stays in dir, which the gate makes the live site again
// before the next push).
func Receive(r io.Reader, dir string, lim Limits) ([]string, error) {
	c := &counter{r: r, max: lim.Total + int64(lim.Entries+2)*1536 + 2<<20}
	tr := tar.NewReader(c)
	seen := map[string]bool{}
	var files []string
	var total int64
	for n := 0; ; n++ {
		h, err := tr.Next()
		if err == io.EOF {
			return files, nil
		}
		if err != nil {
			return files, fmt.Errorf("not a tar stream as the push sends one (%v)", err)
		}
		if n >= lim.Entries {
			return files, fmt.Errorf("over %d entries", lim.Entries)
		}
		name, err := Name(h.Name)
		if err != nil {
			return files, err
		}
		if seen[name] {
			return files, fmt.Errorf("%s twice", name)
		}
		seen[name] = true
		switch h.Typeflag {
		case tar.TypeDir:
			// nothing made: a file's folders are made with it
		case tar.TypeReg, '\x00':
			if h.Size < 0 || h.Size > lim.File {
				return files, fmt.Errorf("%s: over %d MB", name, lim.File>>20)
			}
			if total += h.Size; total > lim.Total {
				return files, fmt.Errorf("over %d MB in all", lim.Total>>20)
			}
			if err := mkdirs(dir, path.Dir(name)); err != nil {
				return files, err
			}
			t := filepath.Join(dir, filepath.FromSlash(name))
			if st, err := os.Lstat(t); err == nil && !st.Mode().IsRegular() {
				// an empty folder (one an older gate let go live) gives way; anything else refuses
				if !st.IsDir() || os.Remove(t) != nil {
					return files, fmt.Errorf("%s: a file where the site has a folder (or something else)", name)
				}
			}
			if err := write(t, io.LimitReader(tr, h.Size), h.Size, time.Now()); err != nil {
				return files, fmt.Errorf("%s: %v", name, err)
			}
			files = append(files, name)
		default:
			return files, fmt.Errorf("%s: not a plain file or folder (a link, a device...)", name)
		}
	}
}

// mkdirs: dir/name's folders, each a folder already or made 755; a step that is anything else
// (a file, a link) is an error, never followed
func mkdirs(dir, name string) error {
	if name == "." {
		return nil
	}
	p := dir
	for _, s := range strings.Split(name, "/") {
		p = filepath.Join(p, s)
		st, err := os.Lstat(p)
		switch {
		case err == nil && st.IsDir():
		case err == nil:
			return fmt.Errorf("%s: a folder where the site has a file (or something else)", name)
		case errors.Is(err, fs.ErrNotExist):
			if err := os.Mkdir(p, 0o755); err != nil {
				return err
			}
			if err := os.Chmod(p, 0o755); err != nil { // (whatever the umask)
				return err
			}
		default:
			return err
		}
	}
	return nil
}

// write: r's size bytes as the file t, written beside it and renamed over it, 644, its time mt
func write(t string, r io.Reader, size int64, mt time.Time) error {
	f, err := os.CreateTemp(filepath.Dir(t), temp+"*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	n, err := io.Copy(f, r)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil && n != size {
		err = io.ErrUnexpectedEOF
	}
	if err == nil {
		err = os.Chmod(tmp, 0o644)
	}
	if err == nil {
		err = os.Chtimes(tmp, mt, mt)
	}
	if err == nil {
		err = os.Rename(tmp, t)
	}
	return err
}

// Copy: dst made to hold src's files, as rsync -a's quick check does: one of the same size and
// time, or the same bytes, is left as it is (its time made src's), any other written beside it and renamed over it (644, its time kept),
// folders 755. With del, what dst has and src hasn't goes, and a file in a folder's place or a
// folder in a file's is replaced; without, that is an error. src holds plain files and folders
// only (the live site, or staging after the gate's checks): anything else is an error.
func Copy(src, dst string, del bool) error {
	err := filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if !d.IsDir() && strings.HasPrefix(d.Name(), temp) {
			return nil // a copy's left-over, never copied
		}
		t := filepath.Join(dst, rel)
		st, terr := os.Lstat(t)
		switch {
		case d.IsDir():
			if terr == nil && !st.IsDir() {
				if !del {
					return fmt.Errorf("%s: a folder where %s has a file", rel, dst)
				}
				if err := os.RemoveAll(t); err != nil {
					return err
				}
				terr = fs.ErrNotExist
			}
			if terr != nil {
				if err := os.Mkdir(t, 0o755); err != nil {
					return err
				}
			}
			return os.Chmod(t, 0o755)
		case d.Type().IsRegular():
			si, err := d.Info()
			if err != nil {
				return err
			}
			if terr == nil && st.Mode().IsRegular() && st.Size() == si.Size() && (st.ModTime().Equal(si.ModTime()) || Same(p, t)) {
				// (the same bytes, sent again: its time made src's, nothing rewritten)
				if err := os.Chtimes(t, si.ModTime(), si.ModTime()); err != nil {
					return err
				}
				if st.Mode().Perm() != 0o644 {
					return os.Chmod(t, 0o644)
				}
				return nil
			}
			if terr == nil && !st.Mode().IsRegular() {
				// an empty folder gives way (one an older gate let go live: review 10's M-1)
				if !del && (!st.IsDir() || os.Remove(t) != nil) {
					return fmt.Errorf("%s: a file where %s has a folder (or something else)", rel, dst)
				}
				if err := os.RemoveAll(t); err != nil {
					return err
				}
			}
			f, err := os.Open(p)
			if err != nil {
				return err
			}
			defer f.Close()
			return write(t, f, si.Size(), si.ModTime())
		default:
			return fmt.Errorf("%s: not a plain file or folder", rel)
		}
	})
	if err != nil {
		return err
	}
	// what dst has and src hasn't: with del, it goes; a copy's left-over temp file always does
	return filepath.WalkDir(dst, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dst, p)
		if rel == "." {
			return nil
		}
		if !d.IsDir() && strings.HasPrefix(d.Name(), temp) {
			return os.Remove(p)
		}
		if !del {
			return nil
		}
		if _, err := os.Lstat(filepath.Join(src, rel)); errors.Is(err, fs.ErrNotExist) {
			if err := os.RemoveAll(p); err != nil {
				return err
			}
			if d.IsDir() {
				return filepath.SkipDir
			}
		} else if err != nil {
			return err
		}
		return nil
	})
}

// Same: a and b hold the same bytes
func Same(a, b string) bool {
	fa, err := os.Open(a)
	if err != nil {
		return false
	}
	defer fa.Close()
	fb, err := os.Open(b)
	if err != nil {
		return false
	}
	defer fb.Close()
	ba, bb := make([]byte, 1<<16), make([]byte, 1<<16)
	for {
		na, ea := io.ReadFull(fa, ba)
		nb, eb := io.ReadFull(fb, bb)
		if na != nb || !bytes.Equal(ba[:na], bb[:nb]) {
			return false
		}
		if ea != nil || eb != nil {
			return ea == eb || (errors.Is(ea, io.EOF) || errors.Is(ea, io.ErrUnexpectedEOF)) && (errors.Is(eb, io.EOF) || errors.Is(eb, io.ErrUnexpectedEOF))
		}
	}
}
