package pages

// projects.json (the /projects API, lib/site.jq's project: Feather's CCS tab shows it, its Donate
// fills in the address) and the proposals' addresses. Each entry must be its proposal's front
// matter as site.jq writes it; only what the backend alone knows (contributions, raised,
// percentage) may be any number. And the address each proposal has on the live site
// (projects.json, live: it passed) is its own: a push can't give it another one, nor give it to
// another proposal, on a page or here, while the proposal is in the repository's newest commit
// (a renamed or removed proposal's goes with it). A proposal new to the site takes the address
// the push gives it, one no other proposal has.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strconv"
	"strings"
)

// a value of an entry: a string, a number (its text), null (or a bool: never right here)
type jv struct {
	kind byte // 's', 'n', 'z', 'b'
	s    string
}

type project map[string]jv

// projectKeys: site.jq's project, every key once
var projectKeys = []string{"address", "author", "contributions", "date", "percentage_funded", "raised_amount",
	"state", "target_amount", "title", "filename", "gitlab_url"}

var states = map[string]string{"fr": "FUNDING-REQUIRED", "wip": "WORK-IN-PROGRESS", "cp": "COMPLETED"}

// readProjects: an array of flat objects (a string, number, null or bool for each value), each
// key once in each, nothing after it; else an error
func readProjects(b []byte) ([]project, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	delim := func(want json.Delim) error {
		t, err := dec.Token()
		if err != nil {
			return err
		}
		if d, ok := t.(json.Delim); !ok || d != want {
			return errors.New("not an array of objects")
		}
		return nil
	}
	if err := delim('['); err != nil {
		return nil, err
	}
	var ps []project
	for dec.More() {
		if err := delim('{'); err != nil {
			return nil, err
		}
		p := project{}
		for dec.More() {
			t, err := dec.Token()
			if err != nil {
				return nil, err
			}
			k, ok := t.(string)
			if !ok {
				return nil, errors.New("not an array of objects")
			}
			if _, dup := p[k]; dup {
				return nil, errors.New("a key twice in an entry (" + strconv.Quote(k) + ")")
			}
			if t, err = dec.Token(); err != nil {
				return nil, err
			}
			switch v := t.(type) {
			case string:
				p[k] = jv{'s', v}
			case json.Number:
				p[k] = jv{'n', string(v)}
			case nil:
				p[k] = jv{'z', ""}
			case bool:
				p[k] = jv{'b', strconv.FormatBool(v)}
			default:
				return nil, errors.New("a value that is an array or object (" + strconv.Quote(k) + ")")
			}
		}
		if err := delim('}'); err != nil {
			return nil, err
		}
		ps = append(ps, p)
	}
	if err := delim(']'); err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("something after the array")
	}
	return ps, nil
}

// addresses: each entry's proposal (filename) and its address, from the projects.json in dir,
// read as it is (none if it can't be read: then every proposal is new to it)
func addresses(dir string) map[string]string {
	m := map[string]string{}
	b, err := os.ReadFile(dir + "/projects.json")
	if err != nil || int64(len(b)) > MaxPage {
		return m
	}
	ps, err := readProjects(b)
	if err != nil {
		return m
	}
	for _, p := range ps {
		if f, a := p["filename"], p["address"]; f.kind == 's' && a.kind == 's' {
			m[f.s] = a.s
		}
	}
	return m
}

// pinned: the live site's addresses that bind: the signed list's, of a proposal in the
// repository's newest commit
func (c *Checker) pinned(live map[string]string) map[string]string {
	m := map[string]string{}
	for f, a := range live {
		if c.l.listed[a] && c.current[strings.TrimSuffix(f, ".md")] {
			m[f] = a
		}
	}
	return m
}

// owner: "" if proposal file may show address a, else why not: its address on the live site is
// another; it has none there and the push's projects.json gives it another, or none; another
// proposal has it, on the live site or in the push's projects.json
func (c *Checker) owner(file, a string) string {
	if p, ok := c.pins[file]; ok && p != a {
		return "its proposal's address on the live site is another (projects.json)"
	}
	if _, ok := c.pins[file]; !ok && c.stage[file] != a {
		return "not its proposal's address in projects.json"
	}
	for f, p := range c.pins {
		if f != file && p == a {
			return "another proposal's address on the live site (" + f + ")"
		}
	}
	for f, p := range c.stage {
		if f != file && p == a {
			return "another proposal's address in projects.json (" + f + ")"
		}
	}
	return ""
}

// num: a JSON number's text as a number
func num(s string) (float64, bool) {
	v, err := strconv.ParseFloat(s, 64)
	return v, err == nil
}

// matches: entry p is front f as site.jq's project writes it
func (c *Checker) matches(p project, f *front) bool {
	str := func(k, want string) bool { return p[k].kind == 's' && same(p[k].s, want) }
	orNull := func(k, want string) bool {
		if want == "" {
			return p[k].kind == 'z'
		}
		return str(k, want)
	}
	if !str("title", f.jname) || !str("author", f.jauthor) || !orNull("date", f.date) || !orNull("state", states[f.layout]) {
		return false
	}
	// the goal: its front matter's (any number for one too large to check: front.go's goal)
	switch t := p["target_amount"]; {
	case t.kind == 'z':
	case t.kind != 'n':
		return false
	case f.amount != "":
		got, ok1 := num(t.s)
		want, ok2 := num(f.amount)
		if !ok1 || !ok2 || got != want {
			return false
		}
	}
	// its own link when its front matter has one; else the backend's, a merge request of the
	// proposals repository (as the page's), or none
	g := p["gitlab_url"]
	switch {
	case f.gitlab != "":
		return str("gitlab_url", f.gitlab)
	case g.kind == 'z':
		return true
	case g.kind == 's':
		return fullmatch(newCtx([]rune(g.s)), c.link)
	}
	return false
}

// projects: "" if projects.json (its bytes b) passes, else why not
func (c *Checker) projects(b []byte) string {
	ps, err := readProjects(b)
	if err != nil {
		return "a projects.json that isn't as ccs-bash writes it (" + err.Error() + ")"
	}
	files, owners := map[string]bool{}, map[string]string{}
	for i, p := range ps {
		if len(p) != len(projectKeys) {
			return "projects.json entry " + strconv.Itoa(i+1) + " has other keys than ccs-bash writes"
		}
		for _, k := range projectKeys {
			if _, ok := p[k]; !ok {
				return "projects.json entry " + strconv.Itoa(i+1) + " has other keys than ccs-bash writes"
			}
		}
		fn := p["filename"]
		if fn.kind != 's' || !strings.HasSuffix(fn.s, ".md") || files[fn.s] {
			return "projects.json entry " + strconv.Itoa(i+1) + ": no proposal's file name, or one twice"
		}
		files[fn.s] = true
		for _, k := range []string{"contributions", "percentage_funded", "raised_amount"} {
			if p[k].kind != 'n' && p[k].kind != 'z' {
				return "projects.json, " + fn.s + ": " + k + " is not a number"
			}
		}
		ok := false
		for _, f := range c.fronts[strings.TrimSuffix(fn.s, ".md")] {
			ok = ok || c.matches(p, f)
		}
		if !ok {
			return "projects.json, " + fn.s + ": not its proposal's front matter in the proposals repository"
		}
		switch a := p["address"]; {
		case a.kind == 'z':
			if _, pin := c.pins[fn.s]; pin {
				return "projects.json, " + fn.s + ": no address, where the live site has its address"
			}
		case a.kind != 's' || !c.l.listed[a.s]:
			return "projects.json, " + fn.s + ": an address that is not in the signed list"
		case owners[a.s] != "":
			return "projects.json, " + fn.s + ": the address " + owners[a.s] + " has"
		default:
			owners[a.s] = fn.s
			if p, pin := c.pins[fn.s]; pin && p != a.s {
				return "projects.json, " + fn.s + ": another address than the live site has for it"
			}
		}
	}
	for f, a := range c.pins {
		if !files[f] {
			return "projects.json without " + f + ", which has an address on the live site"
		}
		if o := owners[a]; o != "" && o != f {
			return "projects.json, " + o + ": the address " + f + " has on the live site"
		}
	}
	return ""
}
