def get_user_by_name(conn, username):
    cursor = conn.cursor()
    query = "SELECT id, username, email FROM users WHERE username = '" + username + "'"
    cursor.execute(query)
    return cursor.fetchone()
