CREATE TABLE id_counters (
    id_type VARCHAR(50) PRIMARY KEY, -- e.g., 'employee', 'shift'
    last_number INT NOT NULL
);

-- Seed values for IDs
INSERT INTO id_counters (id_type, last_number) VALUES ('employee', 0), ('shift', 0);

-- ========================================
-- 2. EMPLOYEE MANAGEMENT (Custom ID + Role)
-- ========================================

CREATE TABLE employees (
    employee_id VARCHAR(10) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100),
    phone VARCHAR(10),
    role VARCHAR(50),
    status ENUM('active', 'inactive') DEFAULT 'active',
    CONSTRAINT unique_name_phone UNIQUE(name,phone)
);
-- ALTER TABLE employees ADD CONSTRAINT unique_name_phone UNIQUE(name,phone);
-- ALTER TABLE employees MODIFY COLUMN phone VARCHAR(10);

-- ========================================
-- 3. SHIFT MANAGEMENT (Custom ID)
-- ========================================

CREATE TABLE shifts (
    shift_id VARCHAR(10) PRIMARY KEY,
    shift_name VARCHAR(50) NOT NULL,
    start_time TIME NOT NULL,
    end_time TIME NOT NULL
);

-- ========================================
-- 4. EMPLOYEE AVAILABILITY
-- ========================================

CREATE TABLE employee_availability (
    availability_id INT AUTO_INCREMENT PRIMARY KEY,
    employee_id VARCHAR(10) NOT NULL,
    -- name VARCHAR(100) NOT NULL,
    available_date DATE NOT NULL,
    FOREIGN KEY (employee_id) REFERENCES employees(employee_id)
	-- FOREIGN KEY (name) REFERENCES employees(name)
);
-- ALTER TABLE employee_availability ADD name VARCHAR(100) NOT NULL;

-- ========================================
-- 5. LEAVE MANAGEMENT
-- ========================================

CREATE TABLE leave_requests (
    leave_id INT AUTO_INCREMENT PRIMARY KEY,
    employee_id VARCHAR(10) NOT NULL,
    leave_start DATE NOT NULL,
    leave_end DATE NOT NULL,
    reason TEXT,
    status ENUM('pending', 'approved', 'rejected') DEFAULT 'pending',
    FOREIGN KEY (employee_id) REFERENCES employees(employee_id)
);

-- ========================================
-- 6. SHIFT ASSIGNMENTS (One per day, no overlaps, respects leave)
-- ========================================

CREATE TABLE shift_assignments (
    assignment_id INT AUTO_INCREMENT PRIMARY KEY,
    employee_id VARCHAR(10) NOT NULL,
	name VARCHAR(100) NOT NULL,
    shift_id VARCHAR(10) NOT NULL,
    shift_date DATE NOT NULL,
    assigned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (employee_id) REFERENCES employees(employee_id),
    FOREIGN KEY (shift_id) REFERENCES shifts(shift_id),
    CONSTRAINT unique_shift_per_day UNIQUE (employee_id, shift_date)
);
-- DROP TABLE shift_assignments;
-- SHOW CREATE TABLE shift_assignments;
-- ALTER TABLE shift_assignments DROP FOREIGN KEY shift_assignments_ibfk_2;
-- ALTER TABLE shift_assignments ADD CONSTRAINT shift_assignments_ibfk_2 FOREIGN KEY (name) REFERENCES employees(name) ON DELETE NO ACTION;
-- ========================================
-- 7. SHIFT SWAP REQUESTS
-- ========================================

CREATE TABLE shift_swap_requests (
    request_id INT AUTO_INCREMENT PRIMARY KEY,
    requester_id VARCHAR(10) NOT NULL,
    requester_name VARCHAR(100) NOT NULL,
    requested_with_id VARCHAR(10) NOT NULL,
	requested_with_name VARCHAR(100) NOT NULL,
    shift_date DATE NOT NULL,
    status ENUM('pending', 'approved', 'rejected') DEFAULT 'pending',
    FOREIGN KEY (requester_id) REFERENCES employees(employee_id),
    FOREIGN KEY (requested_with_id) REFERENCES employees(employee_id)
);
-- DROP TABLE shift_swap_requests;
-- SHOW CREATE TABLE shift_swap_requests;
-- ALTER TABLE shift_swap_requests DROP FOREIGN KEY shift_swap_requests_ibfk_2;
-- ALTER TABLE shift_swap_requests DROP FOREIGN KEY shift_swap_requests_ibfk_4;
-- ALTER TABLE shift_swap_requests ADD CONSTRAINT shift_swap_requests_ibfk_2 FOREIGN KEY (requester_name) REFERENCES employees(name) ON DELETE NO ACTION;
-- ALTER TABLE shift_swap_requests ADD CONSTRAINT shift_swap_requests_ibfk_4 FOREIGN KEY (requested_with_name) REFERENCES employees(name) ON DELETE NO ACTION;
-- ========================================
-- 8. AUDIT LOGS
-- ========================================

CREATE TABLE audit_log (
    log_id INT AUTO_INCREMENT PRIMARY KEY,
    employee_id VARCHAR(10),
    name VARCHAR(100),
    shift_id VARCHAR(10),
    shift_date DATE,
    action ENUM('assigned', 'updated', 'removed', 'auto-assigned'),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ========================================
-- 9. ROBUST TRIGGERS FOR VALIDATION
-- ========================================
-- DROP PROCEDURE IF EXISTS trg_validate_shift_assignment;
DELIMITER $$

CREATE TRIGGER trg_validate_shift_assignment
BEFORE INSERT ON shift_assignments
FOR EACH ROW
BEGIN
    DECLARE emp_status VARCHAR(10);

    -- Check employee status
    SELECT status INTO emp_status FROM employees WHERE employee_id = NEW.employee_id;

    IF emp_status != 'active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Employee is inactive';
    END IF;

    -- Check leave
    IF EXISTS (
        SELECT 1 FROM leave_requests
        WHERE employee_id = NEW.employee_id
          AND status = 'approved'
          AND NEW.shift_date BETWEEN leave_start AND leave_end
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Employee is on leave';
    END IF;

    -- Check overlapping shift
    IF EXISTS (
        SELECT 1
        FROM shift_assignments sa
        JOIN shifts s1 ON sa.shift_id = s1.shift_id
        JOIN shifts s2 ON NEW.shift_id = s2.shift_id
        WHERE sa.employee_id = NEW.employee_id AND sa.shift_date = NEW.shift_date
          AND NOT (s1.end_time <= s2.start_time OR s1.start_time >= s2.end_time)
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Employee already assigned for that time';
    END IF;
END $$
DELIMITER ;

-- ========================================
-- 10. ID GENERATION PROCEDURES (Atomic + Safe)
-- ========================================

DELIMITER $$

CREATE PROCEDURE get_next_id(
    IN id_type_input VARCHAR(50),
    IN prefix VARCHAR(3),
    OUT new_id VARCHAR(10)
)
BEGIN
    DECLARE next_number INT;
    START TRANSACTION;
    UPDATE id_counters
    SET last_number = last_number + 1
    WHERE id_type = id_type_input;

    SELECT last_number INTO next_number FROM id_counters WHERE id_type = id_type_input;
    SET new_id = CONCAT(prefix, LPAD(next_number, 3, '0'));
    COMMIT;
END $$

-- Add Employee
DELIMITER $$
CREATE PROCEDURE add_employee (
    IN emp_name VARCHAR(100),
    IN emp_email VARCHAR(100),
    IN emp_phone VARCHAR(15),
    IN emp_role VARCHAR(50)
)
BEGIN
    DECLARE new_emp_id VARCHAR(10);
    CALL get_next_id('employee', 'EMP', new_emp_id);
    INSERT INTO employees (employee_id, name, email, phone, role)
    VALUES (new_emp_id, emp_name, emp_email, emp_phone, emp_role);
END $$

-- Add Shift
CREATE PROCEDURE add_shift (
    IN shift_name VARCHAR(50),
    IN start_t TIME,
    IN end_t TIME
)
BEGIN
    DECLARE new_shift_id VARCHAR(10);
    CALL get_next_id('shift', 'SFT', new_shift_id);
    INSERT INTO shifts (shift_id, shift_name, start_time, end_time)
    VALUES (new_shift_id, shift_name, start_t, end_t);
END $$

-- Manual Shift Assignment
CREATE PROCEDURE assign_shift (
    IN emp_id VARCHAR(10),
    IN emp_name VARCHAR(100),
    IN shf_id VARCHAR(10),
    IN s_date DATE
)
BEGIN
    INSERT INTO shift_assignments (employee_id, name, shift_id, shift_date)
    VALUES (emp_id, emp_name, shf_id, s_date);
END $$

-- Auto Assign by Role & Availability
-- DROP PROCEDURE IF EXISTS auto_assign_shift;
DELIMITER $$
CREATE PROCEDURE auto_assign_shift (
    IN shift_id_input VARCHAR(10),
    IN date_input DATE,
    IN role_required VARCHAR(50)
)
BEGIN
    DECLARE emp_id VARCHAR(10);
    DECLARE emp_name VARCHAR(100);

    -- Try finding an eligible employee
    SELECT e.employee_id, e.name INTO emp_id, emp_name
    FROM employees e
    JOIN employee_availability a ON e.employee_id = a.employee_id
    WHERE e.status = 'active'
      AND e.role = role_required
      AND a.available_date = date_input
      AND NOT EXISTS (
          SELECT 1 FROM leave_requests lr
          WHERE lr.employee_id = e.employee_id
            AND lr.status = 'approved'
            AND date_input BETWEEN lr.leave_start AND lr.leave_end
      )
      AND NOT EXISTS (
          SELECT 1 FROM shift_assignments sa
          WHERE sa.employee_id = e.employee_id
            AND sa.shift_date = date_input
      )
    LIMIT 1;

    IF emp_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No available employee to auto-assign';
    ELSE
        INSERT INTO shift_assignments (employee_id, name, shift_id, shift_date)
        VALUES (emp_id, emp_name, shift_id_input, date_input);

        INSERT INTO audit_log (employee_id, name, shift_id, shift_date, action)
        VALUES (emp_id, emp_name, shift_id_input, date_input, 'auto-assigned');
    END IF;
END $$
DELIMITER ;

-- ========================================
-- 11. REPORTING VIEWS
-- ========================================

-- Coverage View
CREATE VIEW shift_coverage AS
SELECT s.shift_id, s.shift_name, sa.shift_date, COUNT(sa.assignment_id) AS assigned_count
FROM shifts s
LEFT JOIN shift_assignments sa ON s.shift_id = sa.shift_id
GROUP BY s.shift_id, s.shift_name, sa.shift_date;

-- Workload Summary
CREATE VIEW employee_workload_summary AS
SELECT e.employee_id, e.name, COUNT(sa.assignment_id) AS total_shifts
FROM employees e
LEFT JOIN shift_assignments sa ON e.employee_id = sa.employee_id
GROUP BY e.employee_id, e.name;

-- Unassigned Availability
CREATE VIEW available_unassigned AS
SELECT a.employee_id, a.available_date
FROM employee_availability a
LEFT JOIN shift_assignments sa ON a.employee_id = sa.employee_id AND a.available_date = sa.shift_date
WHERE sa.assignment_id IS NULL;

-- ========================================
-- 12. SAMPLE DATA
-- ========================================
CALL add_employee('Mayurima Sarkar', 'mayurima.sarkar@gmail.com', '9976243102', 'cashier');
CALL add_employee('Rohan Roy', 'rohan@gmail.com', '9877752100', 'cashier');
CALL add_employee('Sneha Das', 'snehadas@gmail.com', '8879516392', 'supervisor');
CALL add_employee('Riya Sen', 'riya.sen@gmail.com', '9876223100', 'manager');
CALL add_employee('Abhik Dey', 'abhikdey@gmail.com', '8067075310', 'supervisor');
CALL add_employee('Himesh Routh', 'routh.himesh@gmail.com', '8795100392', 'cashier');

CALL add_shift('Morning', '08:00:00', '12:00:00');
CALL add_shift('Evening', '14:00:00', '18:00:00');
CALL add_shift('Night', '20:00:00', '00:00:00');

-- Availability
INSERT INTO employee_availability (employee_id, available_date) VALUES
('EMP010', '2025-06-24'),
('EMP011', '2025-06-25'),
('EMP012', '2025-06-25'),
('EMP013', '2025-06-24'),
('EMP014', '2025-06-24'),
('EMP015', '2025-06-24');

-- Approved Leave
INSERT INTO leave_requests (employee_id, leave_start, leave_end, reason, status)
VALUES ('EMP013', '2025-06-24', '2025-06-25', 'Personal leave', 'approved');

-- Swap Request
INSERT INTO shift_swap_requests (requester_id, requester_name, requested_with_id, requested_with_name, shift_date)
VALUES ('EMP010', 'Mayurima Sarkar', 'EMP011', 'Rohan Roy', '2025-06-24');

-- Auto Assign Example
CALL auto_assign_shift('SFT004', '2025-06-24', 'manager');
CALL auto_assign_shift('SFT006', '2025-06-24', 'supervisor');

-- Manual Assign
CALL assign_shift('EMP010', 'Mayurima Sarkar', 'SFT004', '2025-06-24');
CALL assign_shift('EMP013', 'Sneha Das', 'SFT005', '2025-06-24');

SELECT * FROM employees;
SELECT * FROM id_counters;
SELECT * FROM shift_assignments;
SELECT * FROM audit_log;
SELECT * FROM shift_swap_requests;
