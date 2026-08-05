package importer

import (
	"fmt"
	"net/url"
	"path"
	"regexp"
	"strings"
	"time"
	"unicode"

	"github.com/sikaoshenmi/chronicle/internal/capture"
	"gopkg.in/yaml.v3"
)

var (
	h1Pattern      = regexp.MustCompile(`(?m)^#\s+(.+?)\s*$`)
	hashTagPattern = regexp.MustCompile(`(?:^|\s)#([\p{L}\p{N}_/-]+)`)
)

type frontmatter struct {
	title     string
	created   string
	tags      []string
	aliases   []string
	sourceURL string
	todo      bool
	completed bool
	raw       string
	preserve  bool
}

func parseNote(filename, input string, location *time.Location, issues *issueCollector) (string, string, []string, string, bool) {
	input = strings.TrimPrefix(input, "\ufeff")
	input = strings.ReplaceAll(input, "\r\n", "\n")
	input = strings.ReplaceAll(input, "\r", "\n")
	body, metadata, parsed := splitFrontmatter(filename, input, issues)
	body = strings.TrimSpace(body)
	title := metadata.title
	if title == "" && !h1Pattern.MatchString(body) {
		title = strings.TrimSuffix(path.Base(filename), path.Ext(filename))
	}
	if title != "" && !hasMatchingH1(body, title) {
		body = "# " + oneLine(title) + joinSection(body)
	}
	if metadata.sourceURL != "" && !strings.Contains(body, metadata.sourceURL) {
		body += joinSection(metadata.sourceURL)
	}
	if len(metadata.aliases) > 0 {
		body += joinSection("Aliases: " + strings.Join(metadata.aliases, " · "))
	}
	if len(metadata.tags) > 0 {
		existingTags := standaloneTags(body)
		tokens := make([]string, 0, len(metadata.tags))
		for _, value := range metadata.tags {
			token := normalizeTag(value)
			if token == "" {
				issues.add("invalid_tag", filename+": "+value)
				continue
			}
			if token != strings.TrimPrefix(strings.TrimSpace(value), "#") {
				issues.add("normalized_tag", filename+": "+value+" -> "+token)
			}
			hashTag := "#" + token
			if _, exists := existingTags[token]; !exists {
				tokens = append(tokens, hashTag)
				existingTags[token] = struct{}{}
			}
		}
		if len(tokens) > 0 {
			body += joinSection(strings.Join(tokens, " "))
		}
	}
	if metadata.todo {
		body = capture.ApplyImportedTodoState(body, metadata.completed)
	}
	linkText := body
	createdAt := ""
	if metadata.created != "" {
		if parsedTime, err := parseImportTime(metadata.created, location); err == nil {
			createdAt = parsedTime.UTC().Format(time.RFC3339Nano)
		} else {
			issues.add("invalid_created_time", filename+": "+metadata.created)
			metadata.preserve = true
		}
	}
	if metadata.preserve {
		body += joinSection("Imported frontmatter (preserved):\n\n" + indentBlock(neutralizePreservedFrontmatter(metadata.raw)))
	}
	return strings.TrimSpace(body), createdAt, metadata.aliases, linkText, parsed
}

func splitFrontmatter(filename, input string, issues *issueCollector) (string, frontmatter, bool) {
	if input != "---\n" && !strings.HasPrefix(input, "---\n") {
		return input, frontmatter{}, false
	}
	closing := strings.Index(input[4:], "\n---\n")
	closingWidth := len("\n---\n")
	if closing < 0 && strings.HasSuffix(input, "\n---") {
		closing = len(input[4:]) - len("\n---")
		closingWidth = len("\n---")
	}
	if closing < 0 {
		issues.add("malformed_frontmatter", filename)
		return input, frontmatter{}, false
	}
	end := 4 + closing
	if end-4 > maxFrontmatterBytes {
		issues.add("frontmatter_too_large", filename)
		return input, frontmatter{}, false
	}
	raw := input[4:end]
	body := input[end+closingWidth:]
	var document yaml.Node
	if err := yaml.Unmarshal([]byte(raw), &document); err != nil || len(document.Content) != 1 {
		issues.add("malformed_frontmatter", filename)
		return input, frontmatter{}, false
	}
	root := document.Content[0]
	if root.Kind != yaml.MappingNode || containsUnsafeYAML(root) {
		issues.add("unsupported_frontmatter", filename)
		return input, frontmatter{}, false
	}
	result := frontmatter{raw: raw}
	unknown := make([]string, 0)
	createdValues := map[string]string{}
	for index := 0; index+1 < len(root.Content); index += 2 {
		key := strings.TrimSpace(root.Content[index].Value)
		value := root.Content[index+1]
		switch key {
		case "title":
			if text, ok := scalarString(value); ok {
				result.title = text
			} else {
				result.preserve = true
				issues.add("invalid_frontmatter_field", filename+": "+key)
			}
		case "createdAt", "created_at", "created":
			if text, ok := scalarString(value); ok {
				createdValues[key] = text
			} else {
				result.preserve = true
				issues.add("invalid_frontmatter_field", filename+": "+key)
			}
		case "tags", "tag":
			values, ok := stringList(value)
			result.tags = append(result.tags, values...)
			if !ok {
				result.preserve = true
				issues.add("invalid_frontmatter_field", filename+": "+key)
			}
		case "aliases", "alias":
			values, ok := stringList(value)
			result.aliases = append(result.aliases, values...)
			if !ok {
				result.preserve = true
				issues.add("invalid_frontmatter_field", filename+": "+key)
			}
		case "source_url", "source":
			if text, ok := scalarString(value); ok && validHTTPURL(text) {
				result.sourceURL = text
			} else {
				result.preserve = true
				issues.add("invalid_source_url", filename)
			}
		case "completed?", "completed":
			if completed, ok := scalarBool(value); ok {
				result.todo = true
				result.completed = completed
			} else {
				result.preserve = true
				issues.add("invalid_completed_state", filename)
			}
		default:
			result.preserve = true
			unknown = append(unknown, key)
		}
	}
	for _, key := range []string{"createdAt", "created_at", "created"} {
		if value := createdValues[key]; value != "" {
			if result.created != "" && result.created != value {
				issues.add("conflicting_created_time", filename)
			}
			if result.created == "" {
				result.created = value
			}
		}
	}
	if len(unknown) > 0 {
		issues.add("ignored_frontmatter_fields", filename+": "+strings.Join(unknown, ", "))
	}
	if len(result.tags) > maxFrontmatterValues || len(result.aliases) > maxFrontmatterValues {
		result.preserve = true
		issues.add("frontmatter_value_limit", filename)
	}
	result.tags = uniqueLimitedValues(result.tags)
	result.aliases = uniqueLimitedValues(result.aliases)
	return body, result, true
}

func containsUnsafeYAML(node *yaml.Node) bool {
	if node.Kind == yaml.AliasNode || node.Anchor != "" {
		return true
	}
	for _, child := range node.Content {
		if containsUnsafeYAML(child) {
			return true
		}
	}
	return false
}

func scalarString(node *yaml.Node) (string, bool) {
	if node.Kind != yaml.ScalarNode {
		return "", false
	}
	return strings.TrimSpace(node.Value), true
}

func scalarBool(node *yaml.Node) (bool, bool) {
	text, ok := scalarString(node)
	if !ok {
		return false, false
	}
	switch strings.ToLower(text) {
	case "true", "yes", "done", "completed", "1":
		return true, true
	case "false", "no", "open", "0":
		return false, true
	default:
		return false, false
	}
}

func stringList(node *yaml.Node) ([]string, bool) {
	if node.Kind == yaml.ScalarNode {
		text := strings.TrimSpace(node.Value)
		if strings.Contains(text, ",") {
			parts := strings.Split(text, ",")
			result := make([]string, 0, len(parts))
			for _, part := range parts {
				if trimmed := strings.TrimSpace(part); trimmed != "" {
					result = append(result, trimmed)
				}
			}
			if len(result) > maxFrontmatterValues {
				return result[:maxFrontmatterValues], false
			}
			return result, true
		}
		if text != "" {
			return []string{text}, true
		}
		return nil, true
	}
	if node.Kind != yaml.SequenceNode {
		return nil, false
	}
	result := make([]string, 0, len(node.Content))
	valid := true
	for _, item := range node.Content {
		if text, ok := scalarString(item); ok && text != "" {
			result = append(result, text)
		} else {
			valid = false
		}
	}
	if len(result) > maxFrontmatterValues {
		result = result[:maxFrontmatterValues]
		valid = false
	}
	return result, valid
}

func parseImportTime(value string, location *time.Location) (time.Time, error) {
	if parsed, err := time.Parse(time.RFC3339Nano, value); err == nil {
		return parsed, nil
	}
	if strings.Contains(value, " ") {
		if parsed, err := time.Parse(time.RFC3339Nano, strings.Replace(value, " ", "T", 1)); err == nil {
			return parsed, nil
		}
	}
	for _, layout := range []string{"2006-01-02", "2006-01-02 15:04:05", "2006-01-02T15:04:05"} {
		if parsed, err := time.ParseInLocation(layout, value, location); err == nil {
			return parsed, nil
		}
	}
	return time.Time{}, fmt.Errorf("unsupported timestamp %q", value)
}

func validHTTPURL(value string) bool {
	parsed, err := url.Parse(value)
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != ""
}

func hasMatchingH1(body, title string) bool {
	match := h1Pattern.FindStringSubmatch(body)
	return len(match) == 2 && strings.EqualFold(strings.TrimSpace(match[1]), strings.TrimSpace(title))
}

func normalizeTag(value string) string {
	value = strings.TrimPrefix(strings.TrimSpace(value), "#")
	var result strings.Builder
	lastDash := false
	for _, character := range value {
		valid := unicode.IsLetter(character) || unicode.IsNumber(character) || character == '_' || character == '/' || character == '-'
		if valid {
			result.WriteRune(character)
			lastDash = false
		} else if !lastDash {
			result.WriteByte('-')
			lastDash = true
		}
	}
	return strings.Trim(result.String(), "-")
}

func standaloneTags(body string) map[string]struct{} {
	result := make(map[string]struct{})
	for _, match := range hashTagPattern.FindAllStringSubmatch(body, -1) {
		result[match[1]] = struct{}{}
	}
	return result
}

func uniqueLimitedValues(values []string) []string {
	seen := make(map[string]struct{}, min(len(values), maxFrontmatterValues))
	result := make([]string, 0, min(len(values), maxFrontmatterValues))
	for _, value := range values {
		if len(result) >= maxFrontmatterValues {
			break
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func neutralizePreservedFrontmatter(value string) string {
	return strings.ReplaceAll(value, "#todo", `\#todo`)
}

func indentBlock(value string) string {
	lines := strings.Split(strings.TrimSpace(value), "\n")
	for index := range lines {
		lines[index] = "    " + lines[index]
	}
	return strings.Join(lines, "\n")
}

func oneLine(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func joinSection(value string) string {
	if strings.TrimSpace(value) == "" {
		return ""
	}
	return "\n\n" + strings.TrimSpace(value)
}
