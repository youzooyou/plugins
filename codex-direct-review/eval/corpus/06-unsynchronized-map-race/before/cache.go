package cache

import "sync"

type Cache struct {
	data map[string]int
}

func NewCache() *Cache {
	return &Cache{data: make(map[string]int)}
}

// IncrementAll increments the counter for each key concurrently.
func (c *Cache) IncrementAll(keys []string) {
	var wg sync.WaitGroup
	for _, k := range keys {
		wg.Add(1)
		go func(key string) {
			defer wg.Done()
			c.data[key]++
		}(k)
	}
	wg.Wait()
}
