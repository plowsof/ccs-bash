// Package push: the backend's push, site-data.json alone on ssh's stdin (contrib/ccs-push),
// received into the gate's staging folder, and the gate's own copies between staging and the live
// site, in place of rsync: no C parses what the backend sends.
package push

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// temp: the start of a file's name while it is written (write): never a name of the site's, and
// one left by a copy that was killed is removed by the next (review 10's L-3)
const temp = ".ccs-push-"

// Data: the push, r, as dir/site-data.json (written beside it and renamed over it): true; or
// nothing sent, the heartbeat (no bytes, or only NULs: an older backend's empty tar): false. Over
// max bytes, or not JSON's start (an object, "{"): refused. Whether it is site-data.json as
// ccs-bash writes it is ccs-check data's to say.
func Data(r io.Reader, dir string, max int64) (bool, error) {
	b, err := io.ReadAll(io.LimitReader(r, max+1))
	if err != nil {
		return false, err
	}
	if int64(len(b)) > max {
		return false, fmt.Errorf("over %d MB", max>>20)
	}
	if len(bytes.Trim(b, "\x00")) == 0 {
		return false, nil
	}
	if t := bytes.TrimLeft(b, " \t\r\n"); len(t) == 0 || t[0] != '{' {
		return false, errors.New("not site-data.json (a JSON object): a tar from an older backend?")
	}
	return true, write(filepath.Join(dir, "site-data.json"), bytes.NewReader(b), int64(len(b)), time.Now())
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
