package capture

import "testing"

// The tag grammar is the todo facet's public contract: exactly #todo,
// #todo(done), and #todo(done:YYYY-MM-DD) as standalone tokens. These tests
// pin the boundary rules so a regex tweak can't silently start flagging URLs
// or foreign tags as todos.

func TestParseTodoTag(t *testing.T) {
	cases := []struct {
		name string
		text string
		want todoTag
	}{
		{"bare tag alone", "#todo", todoTag{present: true}},
		{"tag after text", "买牛奶 #todo", todoTag{present: true}},
		{"tag before text", "#todo 买牛奶", todoTag{present: true}},
		{"done bare", "买牛奶 #todo(done)", todoTag{present: true, done: true}},
		{"done dated", "买牛奶 #todo(done:2026-07-09)", todoTag{present: true, done: true, doneDate: "2026-07-09"}},
		{"tag then punctuation", "买牛奶 #todo, 顺便买蛋", todoTag{present: true}},
		{"tag at line start", "第一行\n#todo\n第三行", todoTag{present: true}},

		{"no tag", "买牛奶", todoTag{}},
		{"url fragment is not a tag", "https://example.com/#todo", todoTag{}},
		{"longer ascii tag", "check #todos", todoTag{}},
		{"hyphenated tag", "see #todo-list", todoTag{}},
		{"cjk-extended tag", "#todo买牛奶", todoTag{}},
		{"malformed param", "#todo(later)", todoTag{}},
		{"malformed date", "#todo(done:07-09)", todoTag{}},
		{"double hash", "##todo", todoTag{}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := parseTodoTag(c.text); got != c.want {
				t.Fatalf("parseTodoTag(%q) = %+v, want %+v", c.text, got, c.want)
			}
		})
	}
}

func TestParseTodoTag_FirstOccurrenceWins(t *testing.T) {
	got := parseTodoTag("#todo(done:2026-07-01) and later #todo")
	want := todoTag{present: true, done: true, doneDate: "2026-07-01"}
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}
