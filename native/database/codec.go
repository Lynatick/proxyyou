// Package configdb persists typed configuration fields as relational values.
// JSON is accepted only by the subscription importer, never by this codec.
package configdb

import (
	"crypto/sha256"
	"encoding"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"net/netip"
	"reflect"
	"sort"
	"strconv"
)

const CodecVersion = 1

type Field struct {
	Path   string
	Kind   string
	Type   string
	Text   string
	Number int64
	Real   float64
	Bytes  []byte
}

type Codec struct{ types map[string]reflect.Type }

func Fingerprint(fields []Field) string {
	hash := sha256.New()
	for _, field := range fields {
		for _, value := range []string{field.Path, field.Kind, field.Type, field.Text} {
			binary.Write(hash, binary.LittleEndian, uint64(len(value)))
			hash.Write([]byte(value))
		}
		binary.Write(hash, binary.LittleEndian, field.Number)
		binary.Write(hash, binary.LittleEndian, field.Real)
		binary.Write(hash, binary.LittleEndian, uint64(len(field.Bytes)))
		hash.Write(field.Bytes)
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func NewCodec(prototypes ...any) *Codec {
	c := &Codec{types: make(map[string]reflect.Type)}
	for _, value := range []any{false, "", int(0), int64(0), uint64(0), float64(0), []any{}, map[string]any{}} {
		c.Register(value)
	}
	for _, value := range prototypes {
		c.Register(value)
	}
	return c
}

func typeName(t reflect.Type) string {
	if t.Name() != "" {
		return t.PkgPath() + ":" + t.Name()
	}
	switch t.Kind() {
	case reflect.Pointer:
		return "*" + typeName(t.Elem())
	case reflect.Slice:
		return "[]" + typeName(t.Elem())
	case reflect.Array:
		return fmt.Sprintf("[%d]%s", t.Len(), typeName(t.Elem()))
	case reflect.Map:
		return "map[" + typeName(t.Key()) + "]" + typeName(t.Elem())
	default:
		return t.String()
	}
}

func (c *Codec) Register(value any) {
	if value != nil {
		c.register(reflect.TypeOf(value))
	}
}
func (c *Codec) register(t reflect.Type) {
	key := typeName(t)
	if _, exists := c.types[key]; exists {
		return
	}
	c.types[key] = t
	switch t.Kind() {
	case reflect.Pointer, reflect.Slice, reflect.Array:
		c.register(t.Elem())
	case reflect.Map:
		c.register(t.Key())
		c.register(t.Elem())
	case reflect.Struct:
		for i := 0; i < t.NumField(); i++ {
			if t.Field(i).IsExported() {
				c.register(t.Field(i).Type)
			}
		}
	}
}

var addrType = reflect.TypeOf(netip.Addr{})
var prefixType = reflect.TypeOf(netip.Prefix{})

func (c *Codec) Encode(value any) ([]Field, error) {
	var fields []Field
	var visit func(reflect.Value, string, int) error
	visit = func(v reflect.Value, path string, depth int) error {
		if depth > 128 || len(fields) > 100000 {
			return fmt.Errorf("configuration nesting/field limit exceeded")
		}
		field := Field{Path: path}
		if !v.IsValid() {
			field.Kind = "nil"
			fields = append(fields, field)
			return nil
		}
		switch v.Kind() {
		case reflect.Pointer, reflect.Interface, reflect.Map, reflect.Slice:
			if v.IsNil() {
				field.Kind = "nil"
				fields = append(fields, field)
				return nil
			}
		}
		if diagnostic, ok := v.Interface().(error); ok {
			field.Kind = "error"
			field.Text = diagnostic.Error()
			fields = append(fields, field)
			return nil
		}
		if v.Type().ConvertibleTo(addrType) {
			field.Kind = "address"
			field.Text = v.Convert(addrType).Interface().(netip.Addr).String()
			fields = append(fields, field)
			return nil
		}
		if v.Type().ConvertibleTo(prefixType) {
			field.Kind = "prefix"
			field.Text = v.Convert(prefixType).Interface().(netip.Prefix).String()
			fields = append(fields, field)
			return nil
		}
		if v.Kind() == reflect.Struct {
			if marshal, ok := v.Interface().(encoding.BinaryMarshaler); ok {
				data, err := marshal.MarshalBinary()
				if err != nil {
					return err
				}
				field.Kind = "binary"
				field.Bytes = data
				fields = append(fields, field)
				return nil
			}
		}
		switch v.Kind() {
		case reflect.Interface:
			field.Kind = "interface"
			field.Type = typeName(v.Elem().Type())
			if _, ok := c.types[field.Type]; !ok {
				return fmt.Errorf("unregistered configuration type %s", field.Type)
			}
			fields = append(fields, field)
			return visit(v.Elem(), path+"/value", depth+1)
		case reflect.Pointer:
			field.Kind = "pointer"
			fields = append(fields, field)
			return visit(v.Elem(), path+"/value", depth+1)
		case reflect.Struct:
			field.Kind = "struct"
			fields = append(fields, field)
			for i := 0; i < v.NumField(); i++ {
				f := v.Type().Field(i)
				// RawMessage is the source parser's byte cache, not live configuration.
				if !f.IsExported() || f.Name == "RawMessage" || v.Field(i).IsZero() {
					continue
				}
				if err := visit(v.Field(i), path+"/"+f.Name, depth+1); err != nil {
					return err
				}
			}
		case reflect.Slice, reflect.Array:
			if v.Type().Elem().Kind() == reflect.Uint8 && v.Kind() == reflect.Slice {
				field.Kind = "bytes"
				field.Bytes = append([]byte{}, v.Bytes()...)
				fields = append(fields, field)
				return nil
			}
			field.Kind = "list"
			field.Number = int64(v.Len())
			fields = append(fields, field)
			for i := 0; i < v.Len(); i++ {
				if err := visit(v.Index(i), path+"/"+strconv.Itoa(i), depth+1); err != nil {
					return err
				}
			}
		case reflect.Map:
			keys := v.MapKeys()
			sort.Slice(keys, func(i, j int) bool { return fmt.Sprint(keys[i].Interface()) < fmt.Sprint(keys[j].Interface()) })
			field.Kind = "map"
			field.Number = int64(len(keys))
			fields = append(fields, field)
			for i, k := range keys {
				child := path + "/" + strconv.Itoa(i)
				if err := visit(k, child+"/key", depth+1); err != nil {
					return err
				}
				if err := visit(v.MapIndex(k), child+"/value", depth+1); err != nil {
					return err
				}
			}
		case reflect.Bool:
			field.Kind = "bool"
			if v.Bool() {
				field.Number = 1
			}
			fields = append(fields, field)
		case reflect.String:
			field.Kind = "string"
			field.Text = v.String()
			fields = append(fields, field)
		case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
			field.Kind = "int"
			field.Number = v.Int()
			fields = append(fields, field)
		case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
			field.Kind = "uint"
			field.Text = strconv.FormatUint(v.Uint(), 10)
			fields = append(fields, field)
		case reflect.Float32, reflect.Float64:
			if math.IsNaN(v.Float()) || math.IsInf(v.Float(), 0) {
				return fmt.Errorf("non-finite configuration number")
			}
			field.Kind = "float"
			field.Real = v.Float()
			fields = append(fields, field)
		default:
			return fmt.Errorf("unsupported relational configuration type %s", v.Type())
		}
		return nil
	}
	root := reflect.ValueOf(value)
	if root.Kind() == reflect.Pointer && !root.IsNil() {
		root = root.Elem()
	}
	err := visit(root, "", 0)
	return fields, err
}

func (c *Codec) Decode(fields []Field, destination any) error {
	root := reflect.ValueOf(destination)
	if root.Kind() != reflect.Pointer || root.IsNil() {
		return fmt.Errorf("configuration destination must be a non-nil pointer")
	}
	if len(fields) > 100000 {
		return fmt.Errorf("configuration field limit exceeded")
	}
	used := make(map[string]bool, len(fields))
	byPath := make(map[string]Field, len(fields))
	for _, field := range fields {
		if _, ok := byPath[field.Path]; ok {
			return fmt.Errorf("duplicate field path")
		}
		byPath[field.Path] = field
	}
	var read func(reflect.Value, string, int) error
	read = func(v reflect.Value, path string, depth int) error {
		if depth > 128 {
			return fmt.Errorf("configuration nesting limit exceeded")
		}
		field, ok := byPath[path]
		if !ok {
			return fmt.Errorf("missing configuration field %s", path)
		}
		used[path] = true
		if field.Kind == "nil" {
			switch v.Kind() {
			case reflect.Pointer, reflect.Interface, reflect.Map, reflect.Slice:
				v.SetZero()
				return nil
			}
			return fmt.Errorf("null non-nullable configuration field")
		}
		if field.Kind == "error" {
			diagnostic := reflect.ValueOf(errors.New(field.Text))
			if !diagnostic.Type().AssignableTo(v.Type()) {
				return fmt.Errorf("error field type mismatch")
			}
			v.Set(diagnostic)
			return nil
		}
		switch field.Kind {
		case "address":
			a, err := netip.ParseAddr(field.Text)
			if err != nil {
				return err
			}
			if !addrType.ConvertibleTo(v.Type()) {
				return fmt.Errorf("address type mismatch")
			}
			v.Set(reflect.ValueOf(a).Convert(v.Type()))
			return nil
		case "prefix":
			p, err := netip.ParsePrefix(field.Text)
			if err != nil {
				return err
			}
			if !prefixType.ConvertibleTo(v.Type()) {
				return fmt.Errorf("prefix type mismatch")
			}
			v.Set(reflect.ValueOf(p).Convert(v.Type()))
			return nil
		case "binary":
			target, ok := v.Addr().Interface().(encoding.BinaryUnmarshaler)
			if !ok {
				return fmt.Errorf("binary type mismatch")
			}
			return target.UnmarshalBinary(field.Bytes)
		}
		switch v.Kind() {
		case reflect.Pointer:
			if field.Kind != "pointer" {
				return fmt.Errorf("pointer type mismatch")
			}
			v.Set(reflect.New(v.Type().Elem()))
			return read(v.Elem(), path+"/value", depth+1)
		case reflect.Interface:
			if field.Kind != "interface" {
				return fmt.Errorf("interface type mismatch")
			}
			concrete, ok := c.types[field.Type]
			if !ok {
				return fmt.Errorf("unregistered configuration type %s", field.Type)
			}
			item := reflect.New(concrete).Elem()
			if err := read(item, path+"/value", depth+1); err != nil {
				return err
			}
			if !item.Type().AssignableTo(v.Type()) {
				return fmt.Errorf("interface assignment mismatch")
			}
			v.Set(item)
		case reflect.Struct:
			if field.Kind != "struct" {
				return fmt.Errorf("struct type mismatch")
			}
			v.SetZero()
			for i := 0; i < v.NumField(); i++ {
				f := v.Type().Field(i)
				if !f.IsExported() || f.Name == "RawMessage" {
					continue
				}
				child := path + "/" + f.Name
				if _, ok := byPath[child]; ok {
					if err := read(v.Field(i), child, depth+1); err != nil {
						return err
					}
				}
			}
		case reflect.Slice, reflect.Array:
			if field.Kind == "bytes" && v.Kind() == reflect.Slice && v.Type().Elem().Kind() == reflect.Uint8 {
				v.SetBytes(append([]byte{}, field.Bytes...))
				return nil
			}
			if field.Kind != "list" || field.Number < 0 || field.Number > 100000 {
				return fmt.Errorf("invalid list length")
			}
			if v.Kind() == reflect.Slice {
				v.Set(reflect.MakeSlice(v.Type(), int(field.Number), int(field.Number)))
			} else if v.Len() != int(field.Number) {
				return fmt.Errorf("array length mismatch")
			}
			for i := 0; i < v.Len(); i++ {
				if err := read(v.Index(i), path+"/"+strconv.Itoa(i), depth+1); err != nil {
					return err
				}
			}
		case reflect.Map:
			if field.Kind != "map" || field.Number < 0 || field.Number > 100000 {
				return fmt.Errorf("invalid map length")
			}
			v.Set(reflect.MakeMapWithSize(v.Type(), int(field.Number)))
			for i := 0; i < int(field.Number); i++ {
				child := path + "/" + strconv.Itoa(i)
				key := reflect.New(v.Type().Key()).Elem()
				value := reflect.New(v.Type().Elem()).Elem()
				if err := read(key, child+"/key", depth+1); err != nil {
					return err
				}
				if err := read(value, child+"/value", depth+1); err != nil {
					return err
				}
				v.SetMapIndex(key, value)
			}
		case reflect.Bool:
			if field.Kind != "bool" || (field.Number != 0 && field.Number != 1) {
				return fmt.Errorf("bool type mismatch")
			}
			v.SetBool(field.Number == 1)
		case reflect.String:
			if field.Kind != "string" {
				return fmt.Errorf("string type mismatch")
			}
			v.SetString(field.Text)
		case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
			if field.Kind != "int" || v.OverflowInt(field.Number) {
				return fmt.Errorf("integer type mismatch/overflow")
			}
			v.SetInt(field.Number)
		case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
			n, err := strconv.ParseUint(field.Text, 10, 64)
			if field.Kind != "uint" || err != nil || v.OverflowUint(n) {
				return fmt.Errorf("unsigned type mismatch/overflow")
			}
			v.SetUint(n)
		case reflect.Float32, reflect.Float64:
			if field.Kind != "float" || math.IsNaN(field.Real) || math.IsInf(field.Real, 0) || v.OverflowFloat(field.Real) {
				return fmt.Errorf("float type mismatch")
			}
			v.SetFloat(field.Real)
		default:
			return fmt.Errorf("unsupported destination %s", v.Type())
		}
		return nil
	}
	if err := read(root.Elem(), "", 0); err != nil {
		return err
	}
	if len(used) != len(byPath) {
		return fmt.Errorf("unrecognised configuration fields")
	}
	return nil
}
