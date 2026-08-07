package options

import (
	"fmt"

	"github.com/bresilla/geto/src/pkg/ui"
)

type LiteralStringer string

func (l LiteralStringer) String() string {
	return string(l)
}

// Select prompts for a selection from opts.
func Select(msg string, opts []fmt.Stringer) (interface{}, error) {
	if len(opts) == 1 {
		return opts[0], nil
	}
	items := make([]string, len(opts))
	for i, o := range opts {
		items[i] = o.String()
	}
	idx, err := ui.SelectOne(msg, items)
	if err != nil {
		return nil, err
	}
	return opts[idx], nil
}

// SelectCustom prompts for a selection from opts or custom input.
func SelectCustom(msg string, opts []fmt.Stringer) (interface{}, error) {
	if len(opts) == 1 {
		return opts[0], nil
	}
	items := make([]string, len(opts))
	for i, o := range opts {
		items[i] = o.String()
	}
	v, err := ui.SelectOrInput(msg, items)
	if err != nil {
		return nil, err
	}
	for i, it := range items {
		if it == v {
			return opts[i], nil
		}
	}
	return LiteralStringer(v), nil
}
