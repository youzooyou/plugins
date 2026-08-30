package eligibility

// IsEligible reports whether a person meets the minimum age requirement of 18.
func IsEligible(age int) bool {
	return age > 18
}
