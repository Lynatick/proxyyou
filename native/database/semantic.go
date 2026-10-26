package configdb

import (
	"fmt"
	"math"
	"reflect"
	"strings"
	"time"

	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

// AssignSemantic maps typed SQL values to configuration structs. Field names
// use the existing wire tags, but no JSON encoder/decoder participates.
func AssignSemantic(values map[string]any, destination any) error {
	target := reflect.ValueOf(destination)
	if target.Kind() != reflect.Pointer || target.IsNil() {
		return fmt.Errorf("settings target must be a pointer")
	}
	return assignSemantic(values, target.Elem(), 0)
}
func assignSemantic(value any, target reflect.Value, depth int) error {
	if depth > 128 {
		return fmt.Errorf("settings nesting limit exceeded")
	}
	if value == nil {
		switch target.Kind() {
		case reflect.Pointer, reflect.Slice, reflect.Map, reflect.Interface:
			target.SetZero()
		}
		return nil
	}
	if target.Kind() == reflect.Pointer {
		if target.IsNil() {
			target.Set(reflect.New(target.Type().Elem()))
		}
		return assignSemantic(value, target.Elem(), depth+1)
	}
	if target.Type() == reflect.TypeOf(option.DomainStrategy(0)) {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("domain strategy must be a string")
		}
		for candidate := 0; candidate <= 4; candidate++ {
			strategy := option.DomainStrategy(candidate)
			if strategy.String() == text || candidate == 0 && text == "as_is" {
				target.Set(reflect.ValueOf(strategy))
				return nil
			}
		}
		return fmt.Errorf("unsupported domain strategy %q", text)
	}
	if target.Type() == reflect.TypeOf(badoption.Duration(0)) {
		if text, ok := value.(string); ok {
			duration, err := time.ParseDuration(text)
			if err != nil {
				return err
			}
			target.SetInt(int64(duration))
			return nil
		}
	}
	switch target.Kind() {
	case reflect.Struct:
		object, ok := value.(map[string]any)
		if !ok {
			return fmt.Errorf("expected settings object for %s", target.Type())
		}
		for i := 0; i < target.NumField(); i++ {
			field := target.Type().Field(i)
			if !field.IsExported() {
				continue
			}
			name := strings.Split(field.Tag.Get("json"), ",")[0]
			if field.Anonymous && name == "" {
				if err := assignSemantic(object, target.Field(i), depth+1); err != nil {
					return err
				}
				continue
			}
			if name == "-" {
				continue
			}
			if name == "" {
				name = field.Name
			}
			if item, present := object[name]; present {
				if err := assignSemantic(item, target.Field(i), depth+1); err != nil {
					return fmt.Errorf("settings %s: %w", name, err)
				}
			}
		}
	case reflect.Interface:
		target.Set(reflect.ValueOf(value))
	case reflect.Map:
		object, ok := value.(map[string]any)
		if !ok || target.Type().Key().Kind() != reflect.String {
			return fmt.Errorf("expected string-key settings map")
		}
		target.Set(reflect.MakeMapWithSize(target.Type(), len(object)))
		for key, item := range object {
			destination := reflect.New(target.Type().Elem()).Elem()
			if err := assignSemantic(item, destination, depth+1); err != nil {
				return err
			}
			target.SetMapIndex(reflect.ValueOf(key).Convert(target.Type().Key()), destination)
		}
	case reflect.Slice:
		list, ok := value.([]any)
		if !ok {
			return fmt.Errorf("expected settings list")
		}
		target.Set(reflect.MakeSlice(target.Type(), len(list), len(list)))
		for i, item := range list {
			if err := assignSemantic(item, target.Index(i), depth+1); err != nil {
				return err
			}
		}
	case reflect.String:
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("expected settings string")
		}
		target.SetString(text)
	case reflect.Bool:
		flag, ok := value.(bool)
		if !ok {
			return fmt.Errorf("expected settings bool")
		}
		target.SetBool(flag)
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		var number int64
		switch n := value.(type) {
		case int64:
			number = n
		case int:
			number = int64(n)
		case float64:
			if n != math.Trunc(n) || n >= math.MaxInt64 || n < math.MinInt64 {
				return fmt.Errorf("invalid settings integer")
			}
			number = int64(n)
		default:
			return fmt.Errorf("expected settings integer")
		}
		if target.OverflowInt(number) {
			return fmt.Errorf("settings integer overflow")
		}
		target.SetInt(number)
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		var number uint64
		switch n := value.(type) {
		case int64:
			if n < 0 {
				return fmt.Errorf("negative settings uint")
			}
			number = uint64(n)
		case int:
			if n < 0 {
				return fmt.Errorf("negative settings uint")
			}
			number = uint64(n)
		case float64:
			if n < 0 || n != math.Trunc(n) || n >= math.MaxUint64 {
				return fmt.Errorf("invalid settings uint")
			}
			number = uint64(n)
		default:
			return fmt.Errorf("expected settings uint")
		}
		if target.OverflowUint(number) {
			return fmt.Errorf("settings unsigned overflow")
		}
		target.SetUint(number)
	case reflect.Float32, reflect.Float64:
		var number float64
		switch n := value.(type) {
		case float64:
			number = n
		case int64:
			number = float64(n)
		case int:
			number = float64(n)
		default:
			return fmt.Errorf("expected settings float")
		}
		if math.IsNaN(number) || math.IsInf(number, 0) || target.OverflowFloat(number) {
			return fmt.Errorf("invalid settings float")
		}
		target.SetFloat(number)
	default:
		return fmt.Errorf("unsupported settings field %s", target.Type())
	}
	return nil
}
