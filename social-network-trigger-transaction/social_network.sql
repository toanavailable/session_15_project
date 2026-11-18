-- =====================================================================
-- MINI PROJECT: DATABASE "SOCIAL NETWORK" (Trigger + Transaction)
-- MySQL 8.0
-- Lưu ý: cuối file có các lệnh cố ý gây lỗi để kiểm thử ([LỖI DỰ KIẾN]).
-- Trong MySQL Workbench, tắt Query > "Stop Script Execution on Errors" để chạy hết file
-- (hoặc chạy bằng: mysql --force < social_network.sql).
-- =====================================================================

DROP DATABASE IF EXISTS social_network;
CREATE DATABASE social_network CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE social_network;

-- =====================================================================
-- PHẦN 1. CẤU TRÚC BẢNG (khóa ngoại KHÔNG dùng ON DELETE CASCADE)
-- =====================================================================
CREATE TABLE users (
    user_id    INT AUTO_INCREMENT PRIMARY KEY,
    username   VARCHAR(50)  NOT NULL,
    password   VARCHAR(255) NOT NULL,                -- lưu chuỗi băm SHA2, không lưu mật khẩu gốc
    email      VARCHAR(100) NOT NULL,
    created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_users_username UNIQUE (username),
    CONSTRAINT uq_users_email    UNIQUE (email)
) ENGINE = InnoDB;

CREATE TABLE posts (
    post_id       INT AUTO_INCREMENT PRIMARY KEY,
    user_id       INT      NOT NULL,
    content       TEXT     NOT NULL,
    like_count    INT      NOT NULL DEFAULT 0,       -- Trigger tự cập nhật
    comment_count INT      NOT NULL DEFAULT 0,       -- Trigger tự cập nhật
    created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_posts_user FOREIGN KEY (user_id) REFERENCES users (user_id),
    FULLTEXT INDEX ft_posts_content (content)        -- tối ưu tìm kiếm nội dung
) ENGINE = InnoDB;

CREATE TABLE likes (
    like_id    INT AUTO_INCREMENT PRIMARY KEY,
    user_id    INT      NOT NULL,
    post_id    INT      NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_likes_user_post UNIQUE (user_id, post_id),   -- mỗi người chỉ like 1 bài 1 lần
    CONSTRAINT fk_likes_user FOREIGN KEY (user_id) REFERENCES users (user_id),
    CONSTRAINT fk_likes_post FOREIGN KEY (post_id) REFERENCES posts (post_id)
) ENGINE = InnoDB;

CREATE TABLE comments (
    comment_id INT AUTO_INCREMENT PRIMARY KEY,
    post_id    INT      NOT NULL,
    user_id    INT      NOT NULL,
    content    TEXT     NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_comments_post FOREIGN KEY (post_id) REFERENCES posts (post_id),
    CONSTRAINT fk_comments_user FOREIGN KEY (user_id) REFERENCES users (user_id)
) ENGINE = InnoDB;

CREATE TABLE friends (
    user_id    INT         NOT NULL,                 -- người gửi lời mời
    friend_id  INT         NOT NULL,                 -- người nhận lời mời
    status     VARCHAR(20) NOT NULL DEFAULT 'pending',
    created_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, friend_id),
    CONSTRAINT chk_friends_status CHECK (status IN ('pending', 'accepted')),
    CONSTRAINT fk_friends_user   FOREIGN KEY (user_id)   REFERENCES users (user_id),
    CONSTRAINT fk_friends_friend FOREIGN KEY (friend_id) REFERENCES users (user_id),
    INDEX idx_friends_friend (friend_id)
) ENGINE = InnoDB;

-- Mở rộng: nhật ký lưu vết bài viết bị xóa (không có khóa ngoại vì bài gốc đã bị xóa)
CREATE TABLE post_logs (
    log_id       INT AUTO_INCREMENT PRIMARY KEY,
    post_id      INT      NOT NULL,
    post_content TEXT     NOT NULL,
    deleted_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE = InnoDB;

-- =====================================================================
-- PHẦN 2. TRIGGER (tạo trước khi chèn dữ liệu mẫu để bộ đếm tự tính)
-- =====================================================================
DELIMITER //

-- Chức năng 3: tự động đếm like
CREATE TRIGGER tg_after_like_insert
AFTER INSERT ON likes
FOR EACH ROW
BEGIN
    UPDATE posts
    SET like_count = like_count + 1
    WHERE post_id = NEW.post_id;
END //

CREATE TRIGGER tg_after_like_delete
AFTER DELETE ON likes
FOR EACH ROW
BEGIN
    UPDATE posts
    SET like_count = like_count - 1
    WHERE post_id = OLD.post_id
      AND like_count > 0;                            -- chặn giá trị đếm xuống dưới 0
END //

-- Chức năng 3: tự động đếm comment
CREATE TRIGGER tg_after_comment_insert
AFTER INSERT ON comments
FOR EACH ROW
BEGIN
    UPDATE posts
    SET comment_count = comment_count + 1
    WHERE post_id = NEW.post_id;
END //

CREATE TRIGGER tg_after_comment_delete
AFTER DELETE ON comments
FOR EACH ROW
BEGIN
    UPDATE posts
    SET comment_count = comment_count - 1
    WHERE post_id = OLD.post_id
      AND comment_count > 0;                         -- chặn giá trị đếm xuống dưới 0
END //

-- Chức năng 6: kiểm soát kết bạn
CREATE TRIGGER tg_before_friend_insert
BEFORE INSERT ON friends
FOR EACH ROW
BEGIN
    -- Lỗi 1: tự kết bạn với chính mình
    IF NEW.user_id = NEW.friend_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Không thể tự kết bạn với chính mình';
    END IF;

    -- Lỗi 2: cặp user_id - friend_id đã tồn tại
    IF EXISTS (SELECT 1 FROM friends
               WHERE user_id = NEW.user_id AND friend_id = NEW.friend_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Lời mời kết bạn này đã tồn tại';
    END IF;

    -- Lỗi 3: lời mời đảo chiều (người kia đã gửi lời mời cho mình)
    IF EXISTS (SELECT 1 FROM friends
               WHERE user_id = NEW.friend_id AND friend_id = NEW.user_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Người này đã gửi lời mời kết bạn cho bạn, hãy chấp nhận lời mời đó';
    END IF;
END //

-- Mở rộng: lưu vết bài viết bị xóa vĩnh viễn
CREATE TRIGGER tg_after_post_delete
AFTER DELETE ON posts
FOR EACH ROW
BEGIN
    INSERT INTO post_logs (post_id, post_content)
    VALUES (OLD.post_id, OLD.content);
END //

DELIMITER ;

-- =====================================================================
-- PHẦN 3. VIEW VÀ STORED PROCEDURE
-- =====================================================================

-- Chức năng 1: khung nhìn hồ sơ (không có password)
CREATE OR REPLACE VIEW view_user_info AS
SELECT user_id, username, email, created_at
FROM users;

DELIMITER //

-- Chức năng 2: đăng ký tài khoản
CREATE PROCEDURE sp_add_user(
    IN p_username VARCHAR(50),
    IN p_password VARCHAR(255),
    IN p_email    VARCHAR(100)
)
BEGIN
    IF EXISTS (SELECT 1 FROM users WHERE email = p_email) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Email đã được sử dụng';
    END IF;

    IF EXISTS (SELECT 1 FROM users WHERE username = p_username) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Tên đăng nhập đã được sử dụng';
    END IF;

    INSERT INTO users (username, password, email)
    VALUES (p_username, SHA2(p_password, 256), p_email);

    SELECT LAST_INSERT_ID() AS new_user_id, 'Đăng ký tài khoản thành công' AS message;
END //

-- Chức năng 4: thống kê hoạt động của từng user
CREATE PROCEDURE sp_user_activity_report()
BEGIN
    SELECT
        u.user_id,
        u.username,
        COUNT(DISTINCT p.post_id)    AS total_posts,     -- số bài viết đã đăng
        COUNT(DISTINCT l.like_id)    AS total_likes,     -- số lượt like đã thả
        COUNT(DISTINCT c.comment_id) AS total_comments   -- số bình luận đã viết
    FROM users AS u
    LEFT JOIN posts    AS p ON p.user_id = u.user_id
    LEFT JOIN likes    AS l ON l.user_id = u.user_id
    LEFT JOIN comments AS c ON c.user_id = u.user_id
    GROUP BY u.user_id, u.username
    ORDER BY u.user_id;
END //

-- Chức năng 5: xóa tài khoản toàn vẹn (All-or-Nothing)
CREATE PROCEDURE sp_delete_user(IN p_user_id INT)
BEGIN
    DECLARE v_username VARCHAR(50) DEFAULT NULL;

    -- Bất kỳ lệnh DELETE nào lỗi: hoàn tác toàn bộ rồi báo lỗi cho người gọi
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_user_posts;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- Khóa dòng user để không ai thao tác trên tài khoản trong lúc xóa
    SELECT username INTO v_username
    FROM users
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_username IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Người dùng không tồn tại';
    END IF;

    -- Lưu danh sách bài viết của user ra bảng tạm.
    -- Không dùng subquery trực tiếp trên posts trong lệnh DELETE likes/comments, vì Trigger
    -- của likes/comments cập nhật posts -> MySQL báo lỗi 1442 nếu câu lệnh gốc đang đọc posts.
    DROP TEMPORARY TABLE IF EXISTS tmp_user_posts;
    CREATE TEMPORARY TABLE tmp_user_posts (post_id INT PRIMARY KEY);
    INSERT INTO tmp_user_posts (post_id)
    SELECT post_id FROM posts WHERE user_id = p_user_id;

    -- 1. likes: like do user thả + like của người khác trên bài của user
    DELETE FROM likes
    WHERE user_id = p_user_id
       OR post_id IN (SELECT post_id FROM tmp_user_posts);

    -- 2. comments: comment do user viết + comment của người khác trên bài của user
    DELETE FROM comments
    WHERE user_id = p_user_id
       OR post_id IN (SELECT post_id FROM tmp_user_posts);

    -- 3. friends: quan hệ ở cả 2 chiều
    DELETE FROM friends
    WHERE user_id = p_user_id
       OR friend_id = p_user_id;

    -- Giả lập sự cố giữa chừng để kiểm thử ROLLBACK (chỉ khi bật biến phiên)
    IF @simulate_delete_error = 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Sự cố hệ thống khi đang xóa tài khoản';
    END IF;

    -- 4. posts (Trigger tg_after_post_delete tự lưu vết vào post_logs)
    DELETE FROM posts
    WHERE user_id = p_user_id;

    -- 5. users (bảng cha)
    DELETE FROM users
    WHERE user_id = p_user_id;

    COMMIT;
    DROP TEMPORARY TABLE IF EXISTS tmp_user_posts;

    SELECT CONCAT('Đã xóa toàn bộ dữ liệu của tài khoản ', v_username) AS message;
END //

DELIMITER ;

-- =====================================================================
-- PHẦN 4. DỮ LIỆU MẪU (Trigger tự cập nhật like_count / comment_count)
-- =====================================================================
INSERT INTO users (username, password, email) VALUES
    ('an_nguyen',  SHA2('An@12345',   256), 'an.nguyen@gmail.com'),
    ('binh_tran',  SHA2('Binh@12345', 256), 'binh.tran@gmail.com'),
    ('cuong_le',   SHA2('Cuong@1234', 256), 'cuong.le@gmail.com'),
    ('dung_pham',  SHA2('Dung@12345', 256), 'dung.pham@gmail.com'),
    ('ha_vu',      SHA2('Ha@1234567', 256), 'ha.vu@gmail.com');        -- user mới, chưa tương tác

INSERT INTO posts (user_id, content) VALUES
    (1, 'Hôm nay mình bắt đầu học MySQL, cảm thấy rất thú vị!'),
    (2, 'Chia sẻ tài liệu về Trigger và Transaction cho mọi người.'),
    (3, 'Cuối tuần này cả nhóm đi Đà Lạt nhé.'),
    (1, 'Mẹo tối ưu truy vấn MySQL bằng Index.'),
    (4, 'Bài viết đầu tiên của mình trên mạng xã hội này.');

INSERT INTO likes (user_id, post_id) VALUES
    (2, 1), (3, 1), (4, 1),
    (1, 2), (3, 2),
    (1, 3),
    (2, 4);

INSERT INTO comments (post_id, user_id, content) VALUES
    (1, 2, 'Cố lên bạn ơi!'),
    (1, 3, 'MySQL dễ mà, học vài tuần là quen.'),
    (2, 1, 'Cảm ơn bạn đã chia sẻ.'),
    (2, 3, 'Tài liệu rất hữu ích.'),
    (2, 4, 'Mình lưu lại để đọc dần.'),
    (4, 2, 'Mẹo hay quá!');

INSERT INTO friends (user_id, friend_id, status) VALUES
    (1, 2, 'accepted'),
    (3, 1, 'accepted'),
    (1, 4, 'accepted'),
    (1, 5, 'pending'),
    (2, 3, 'accepted');

-- =====================================================================
-- PHẦN 5. KIỂM THỬ
-- =====================================================================

-- T1. View hồ sơ: không có cột password
SELECT * FROM view_user_info;

-- T2. Đăng ký tài khoản hợp lệ
CALL sp_add_user('lan_do', 'Lan@123456', 'lan.do@gmail.com');

-- T3. Bộ đếm do Trigger tự tính từ dữ liệu mẫu
SELECT post_id, user_id, like_count, comment_count FROM posts ORDER BY post_id;
-- Mong đợi: post 1 = 3/2, post 2 = 2/3, post 3 = 1/0, post 4 = 1/1, post 5 = 0/0

-- T3.1 Thêm và bỏ like, thêm và xóa comment
INSERT INTO likes (user_id, post_id) VALUES (5, 5);                -- post 5: like 0 -> 1
DELETE FROM likes WHERE user_id = 1 AND post_id = 3;               -- post 3: like 1 -> 0
INSERT INTO comments (post_id, user_id, content) VALUES (3, 4, 'Cho mình đi với!'); -- post 3: comment 0 -> 1
DELETE FROM comments WHERE post_id = 4 AND user_id = 2;            -- post 4: comment 1 -> 0
SELECT post_id, like_count, comment_count FROM posts WHERE post_id IN (3, 4, 5);

-- T3.2 Chặn giá trị đếm xuống dưới 0: giả lập bộ đếm bị lệch về 0 rồi xóa like
UPDATE posts SET like_count = 0 WHERE post_id = 5;
DELETE FROM likes WHERE user_id = 5 AND post_id = 5;
SELECT post_id, like_count FROM posts WHERE post_id = 5;           -- Mong đợi: vẫn 0, không âm

-- T4. Báo cáo hoạt động (user ha_vu và lan_do vẫn hiển thị với giá trị 0)
CALL sp_user_activity_report();

-- T5. Kết bạn hợp lệ
INSERT INTO friends (user_id, friend_id) VALUES (4, 5);
SELECT * FROM friends ORDER BY user_id, friend_id;

-- T6. Tìm kiếm Full-Text trên nội dung bài viết
SELECT post_id, content
FROM posts
WHERE MATCH (content) AGAINST ('+MySQL' IN BOOLEAN MODE);

-- T7. Xóa bài viết không có tương tác -> Trigger lưu vết vào post_logs
DELETE FROM posts WHERE post_id = 5;
SELECT * FROM post_logs;

-- T8. Xóa tài khoản toàn vẹn: xóa binh_tran (user 2)
SET @simulate_delete_error = 0;
CALL sp_delete_user(2);

SELECT * FROM view_user_info;
SELECT post_id, user_id, like_count, comment_count FROM posts ORDER BY post_id;
SELECT * FROM post_logs;
-- Kiểm tra không còn dữ liệu mồ côi của user 2 (mong đợi: tất cả bằng 0)
SELECT
    (SELECT COUNT(*) FROM posts    WHERE user_id = 2)                      AS orphan_posts,
    (SELECT COUNT(*) FROM likes    WHERE user_id = 2)                      AS orphan_likes,
    (SELECT COUNT(*) FROM comments WHERE user_id = 2)                      AS orphan_comments,
    (SELECT COUNT(*) FROM friends  WHERE user_id = 2 OR friend_id = 2)     AS orphan_friends;

-- =====================================================================
-- PHẦN 6. CÁC TRƯỜNG HỢP LỖI [LỖI DỰ KIẾN]
-- =====================================================================
-- E1. Đăng ký trùng email -> 'Lỗi: Email đã được sử dụng'
CALL sp_add_user('an_nguyen_2', 'Abc@12345', 'an.nguyen@gmail.com');

-- E2. Đăng ký trùng username -> 'Lỗi: Tên đăng nhập đã được sử dụng'
CALL sp_add_user('an_nguyen', 'Abc@12345', 'an.moi@gmail.com');

-- E3. Tự kết bạn với chính mình
INSERT INTO friends (user_id, friend_id) VALUES (3, 3);

-- E4. Trùng lặp lời mời (1 -> 4 đã tồn tại)
INSERT INTO friends (user_id, friend_id) VALUES (1, 4);

-- E5. Lời mời đảo chiều (đã có 1 -> 5, nay 5 gửi ngược cho 1)
INSERT INTO friends (user_id, friend_id) VALUES (5, 1);

-- E6. Sự cố giữa chừng khi xóa tài khoản cuong_le (user 3) -> ROLLBACK toàn bộ
SET @simulate_delete_error = 1;
CALL sp_delete_user(3);
SET @simulate_delete_error = 0;

-- Sau E6: dữ liệu của user 3 còn nguyên (likes, comments, friends, posts không bị mất)
SELECT
    (SELECT COUNT(*) FROM users    WHERE user_id = 3)                      AS user_3,
    (SELECT COUNT(*) FROM posts    WHERE user_id = 3)                      AS posts_3,
    (SELECT COUNT(*) FROM likes    WHERE user_id = 3)                      AS likes_3,
    (SELECT COUNT(*) FROM comments WHERE user_id = 3)                      AS comments_3,
    (SELECT COUNT(*) FROM friends  WHERE user_id = 3 OR friend_id = 3)     AS friends_3;
